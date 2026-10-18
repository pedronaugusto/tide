//! tide in the shapes it serves: a calendar spent by actions, clocks at rates
//! the host changes, jumps that pass what was due, several calendars on one
//! clock, a resume that catches up, and a restore to an earlier moment that
//! replays exactly. Each writes through a riverrun store, counting its writes.

const std = @import("std");
const facts = @import("riverrun").facts;
const Tide = @import("Tide.zig");
const calendar = @import("calendar.zig");
const snapshot = @import("snapshot.zig");

const gpa = std.testing.allocator;

const world: facts.ScopeId = .fromRaw(0);

const time: facts.FactId = .fromRaw(0);
const slot: facts.FactId = .fromRaw(1);
const day: facts.FactId = .fromRaw(2);
const weekday: facts.FactId = .fromRaw(3);
const days_left: facts.FactId = .fromRaw(4);
const ship: facts.FactId = .fromRaw(5);
const drift: facts.FactId = .fromRaw(6);
const moon: facts.FactId = .fromRaw(7);

const schema: facts.Schema = .{ .scopes = &.{"world"}, .facts = &.{
    .{ .name = "time", .scope = world, .kind = .int, .role = .game },
    .{ .name = "slot", .scope = world, .kind = .one_of, .items = &.{ "morning", "noon", "afternoon", "evening" }, .role = .game },
    .{ .name = "day", .scope = world, .kind = .int, .role = .game },
    .{ .name = "weekday", .scope = world, .kind = .one_of, .items = &.{ "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday" }, .role = .game },
    .{ .name = "days_left", .scope = world, .kind = .int, .role = .game },
    .{ .name = "ship", .scope = world, .kind = .int, .role = .game },
    .{ .name = "drift", .scope = world, .kind = .int, .role = .game },
    .{ .name = "moon", .scope = world, .kind = .one_of, .items = &.{ "new", "waxing", "full", "waning" }, .role = .game },
} };

/// A store that counts what is written to it, over riverrun's default store.
const Counted = struct {
    memory: facts.Memory,
    writes: [8]u32 = @splat(0),

    fn init() !Counted {
        return .{ .memory = try .init(gpa, schema) };
    }

    fn deinit(c: *Counted) void {
        c.memory.deinit();
    }

    fn store(c: *Counted) facts.Store {
        return .{ .ptr = c, .vtable = &vtable };
    }

    fn int(c: *const Counted, f: facts.FactId) i64 {
        return c.memory.get(f).int;
    }

    fn of(c: *const Counted, f: facts.FactId) u16 {
        return c.memory.get(f).one_of;
    }

    const vtable: facts.Store.VTable = .{
        .get = struct {
            fn f(ptr: *anyopaque, fact: facts.FactId) facts.Value {
                const c: *Counted = @ptrCast(@alignCast(ptr)); // safe: made by `store` from a *Counted
                return c.memory.get(fact);
            }
        }.f,
        .set = struct {
            fn f(ptr: *anyopaque, fact: facts.FactId, v: facts.Value) facts.SetError!void {
                const c: *Counted = @ptrCast(@alignCast(ptr)); // safe: made by `store` from a *Counted
                c.writes[fact.raw()] += 1;
                return c.memory.set(fact, v);
            }
        }.f,
        .changes = struct {
            fn f(ptr: *anyopaque) *const facts.Changes {
                const c: *Counted = @ptrCast(@alignCast(ptr)); // safe: made by `store` from a *Counted
                return &c.memory.changes;
            }
        }.f,
    };
};

/// Persona's week: four slots a day, the week a cycle, a year of real months.
const persona: Tide.CalendarDecl = .{
    .clock = .fromRaw(0),
    .decl = calendar.persona,
    .binding = .{ .counts = &.{ null, day }, .places = &.{slot}, .cycles = &.{weekday} },
};

const clock: Tide.ClockId = .fromRaw(0);
const year: Tide.CalendarId = .fromRaw(0);

test "a day spent by actions at rate zero: slots pass, the day rolls over, days_left counts down" {
    var s = try Counted.init();
    defer s.deinit();
    // the fifth day's morning is the deadline
    const deadline: u64 = 5 * 4;
    var t = try Tide.init(gpa, .{
        .clocks = &.{.{ .name = "world", .fact = time, .rate = .zero }},
        .calendars = &.{persona},
        .derived = &.{.{ .fact = days_left, .what = .{ .until = .{ .clock = clock, .at = deadline, .per = .{ .unit = .{ .calendar = year, .unit = 1 } } } } }},
        .store = s.store(),
    });
    defer t.deinit();
    try t.sync();
    try std.testing.expectEqual(@as(i64, 5), s.int(days_left));
    var buf: [4]Tide.Due = undefined;
    // real time passes and the world does not move
    _ = try t.elapse(clock, 1_000_000, &buf);
    try std.testing.expectEqual(@as(i64, 0), s.int(time));
    // three actions spend the morning, noon and afternoon
    for (0..3) |_| _ = try t.advance(clock, 1, &buf);
    try std.testing.expectEqual(@as(u16, 3), s.of(slot));
    try std.testing.expectEqual(@as(i64, 5), s.int(days_left));
    const day_writes = s.writes[day.raw()];
    // the evening's action rolls the day over, and the countdown follows
    _ = try t.advance(clock, 1, &buf);
    try std.testing.expectEqual(@as(u16, 0), s.of(slot));
    try std.testing.expectEqual(@as(i64, 1), s.int(day));
    try std.testing.expectEqual(@as(u16, 1), s.of(weekday));
    try std.testing.expectEqual(@as(i64, 4), s.int(days_left));
    try std.testing.expectEqual(day_writes + 1, s.writes[day.raw()]);
    // an action within the day writes the slot and nothing that did not change
    const left_writes = s.writes[days_left.raw()];
    _ = try t.advance(clock, 1, &buf);
    try std.testing.expectEqual(day_writes + 1, s.writes[day.raw()]);
    try std.testing.expectEqual(left_writes, s.writes[days_left.raw()]);
    // past the deadline it stays at zero
    _ = try t.advance(clock, 40, &buf);
    try std.testing.expectEqual(@as(i64, 0), s.int(days_left));
}

test "two clocks at rates the host changes, exact, and drift crossing its year at exactly the right step" {
    var s = try Counted.init();
    defer s.deinit();
    // ticks are seconds; a year of them
    const year_s: u64 = 365 * 24 * 3600;
    const earth: Tide.ClockId = .fromRaw(0);
    const vessel: Tide.ClockId = .fromRaw(1);
    var t = try Tide.init(gpa, .{
        .clocks = &.{ .{ .name = "earth", .fact = time }, .{ .name = "ship", .fact = ship } },
        .derived = &.{.{ .fact = drift, .what = .{ .drift = .{ .a = earth, .b = vessel, .per = year_s } } }},
        .store = s.store(),
    });
    defer t.deinit();
    var buf: [1]Tide.Due = undefined;
    // near light's speed the ship's clock runs slow: 3 seconds aboard for every 5 at home
    try t.setRate(vessel, .{ .ticks = 3, .per = 5 });
    // a tenth of a year a step, each in ten elapses
    const step = year_s / 10;
    var steps: u64 = 0;
    while (s.int(drift) == 0) : (steps += 1) {
        for (0..10) |_| {
            _ = try t.elapse(earth, step / 10, &buf);
            _ = try t.elapse(vessel, step / 10, &buf);
        }
    }
    // the ship loses two fifths of each year, a whole one in two and a half: the 25th step crosses it
    try std.testing.expectEqual(@as(u64, 25), steps);
    try std.testing.expectEqual(@as(u64, 25 * step), t.now(earth));
    try std.testing.expectEqual(@as(u64, 25 * step * 3 / 5), t.now(vessel));
    // the host slows the ship to a crawl, then stops it; earth runs on
    try t.setRate(vessel, .{ .ticks = 1, .per = 10 });
    _ = try t.elapse(earth, year_s, &buf);
    _ = try t.elapse(vessel, year_s, &buf);
    try t.pause(vessel, true);
    _ = try t.elapse(earth, year_s, &buf);
    _ = try t.elapse(vessel, year_s, &buf);
    try std.testing.expectEqual(@as(u64, 25 * step * 3 / 5 + year_s / 10), t.now(vessel));
    const want = @divFloor(@as(i128, t.now(earth)) - t.now(vessel), year_s);
    try std.testing.expectEqual(@as(i64, @intCast(want)), s.int(drift));
}

test "a week skipped: each occurrence comes due once, in order, or once for all under `once`" {
    var t = try Tide.init(gpa, .{ .clocks = &.{.{ .name = "world" }}, .calendars = &.{persona} });
    defer t.deinit();
    const cal = t.calendar(year);
    const sunday_evening = [_]calendar.Want{ .{ .what = .{ .cycle = 0 }, .value = 6 }, .{ .what = .{ .place = 0 }, .value = 3 } };
    const first = try cal.next(0, &sunday_evening);
    // the market every evening, the church every Sunday evening, a letter on the third day's noon,
    // and the market again for a host that only wants to know it happened
    _ = try t.every(clock, .{ .first = 3, .every = .{ .ticks = 4 } }, 1);
    _ = try t.every(clock, .{ .first = first, .every = .{ .units = .{ .calendar = 0, .unit = 1, .n = 7 } } }, 2);
    _ = try t.at(clock, 2 * 4 + 1, 3);
    _ = try t.every(clock, .{ .first = 3, .every = .{ .ticks = 4 }, .policy = .once }, 4);
    var buf: [32]Tide.Due = undefined;
    const got = try t.advance(clock, 7 * 4, &buf);
    try std.testing.expectEqual(@as(u64, 0), got.left);
    var keys: [32]u64 = undefined;
    var ats: [32]u64 = undefined;
    for (got.due, 0..) |d, i| {
        keys[i] = d.key;
        ats[i] = d.at;
    }
    // by tick, then by when each was scheduled; the coalesced market once, at its first, standing for seven
    try std.testing.expectEqualSlices(u64, &.{ 1, 4, 1, 3, 1, 1, 1, 1, 1, 2 }, keys[0..got.due.len]);
    try std.testing.expectEqualSlices(u64, &.{ 3, 3, 7, 9, 11, 15, 19, 23, 27, 27 }, ats[0..got.due.len]);
    try std.testing.expectEqual(@as(u64, 7), got.due[1].count);
    for (got.due) |d| if (d.key != 4) try std.testing.expectEqual(@as(u64, 1), d.count);
}

test "a full buffer stops the clock where it is, and the rest comes due on the next advance" {
    var t = try Tide.init(gpa, .{ .clocks = &.{.{ .name = "world" }} });
    defer t.deinit();
    _ = try t.every(clock, .{ .first = 10, .every = .{ .ticks = 10 }, .times = 5 }, 7);
    var buf: [2]Tide.Due = undefined;
    const a = try t.advance(clock, 100, &buf);
    try std.testing.expectEqual(@as(usize, 2), a.due.len);
    try std.testing.expectEqual(@as(u64, 30), t.now(clock));
    try std.testing.expectEqual(@as(u64, 70), a.left);
    const b = try t.advance(clock, a.left, &buf);
    try std.testing.expectEqual(@as(u64, 30), b.due[0].at);
    const c = try t.advance(clock, b.left, &buf);
    try std.testing.expectEqual(@as(usize, 1), c.due.len);
    try std.testing.expectEqual(@as(u64, 50), c.due[0].at);
    try std.testing.expectEqual(@as(u64, 0), c.left);
    try std.testing.expectEqual(@as(u64, 100), t.now(clock));
}

test "two calendars on one clock: a moon beside the week" {
    var s = try Counted.init();
    defer s.deinit();
    const lunar: Tide.CalendarDecl = .{ .clock = clock, .decl = .{
        .name = "moon",
        .units = &.{ .{ .name = "slot", .size = .{ .fixed = 1 } }, .{ .name = "day", .size = .{ .fixed = 4 } } },
        .cycles = &.{.{ .name = "phase", .unit = 1, .length = 4, .names = &.{ "new", "waxing", "full", "waning" }, .offset = 2 }},
    }, .binding = .{ .cycles = &.{moon} } };
    var t = try Tide.init(gpa, .{ .clocks = &.{.{ .name = "world", .fact = time }}, .calendars = &.{ persona, lunar }, .store = s.store() });
    defer t.deinit();
    try t.sync();
    try std.testing.expectEqual(@as(u16, 2), s.of(moon));
    var buf: [1]Tide.Due = undefined;
    _ = try t.advance(clock, 4 * 3, &buf);
    try std.testing.expectEqual(@as(u16, 1), s.of(moon));
    try std.testing.expectEqual(@as(u16, 3), s.of(weekday));
}

// Elapses `elapsed` on `t`, going on until nothing is left; how many came due.
fn catchUp(t: *Tide, elapsed: u64, buf: []Tide.Due) !usize {
    var a = try t.elapse(clock, elapsed, buf);
    var n = a.due.len;
    while (a.left > 0) {
        a = try t.advance(clock, a.left, buf);
        n += a.due.len;
    }
    return n;
}

test "catching up on an absence is the same however the time is handed over" {
    const minute: Tide.ClockDecl = .{ .name = "world", .rate = .{ .ticks = 1, .per = 60 } };
    var whole = try Tide.init(gpa, .{ .clocks = &.{minute} });
    defer whole.deinit();
    var pieces = try Tide.init(gpa, .{ .clocks = &.{minute} });
    defer pieces.deinit();
    for ([_]*Tide{ &whole, &pieces }) |t| _ = try t.every(clock, .{ .first = 0, .every = .{ .ticks = 60 } }, 1);
    // three days away, in seconds, at a minute a tick: handed over at once, and in odd pieces, a small buffer each
    var buf: [5]Tide.Due = undefined;
    var away: u64 = 3 * 24 * 3600;
    const n_whole = try catchUp(&whole, away, &buf);
    var n_pieces: usize = 0;
    while (away > 0) {
        const piece = @min(away, 7919);
        away -= piece;
        n_pieces += try catchUp(&pieces, piece, &buf);
    }
    try std.testing.expectEqual(@as(u64, 3 * 24 * 60), whole.now(clock));
    try std.testing.expectEqual(whole.now(clock), pieces.now(clock));
    try std.testing.expectEqual(@as(usize, 3 * 24 + 1), n_whole);
    try std.testing.expectEqual(n_whole, n_pieces);
}

test "a restore to an earlier moment replays what comes due exactly as the first time" {
    var s = try Counted.init();
    defer s.deinit();
    var t = try Tide.init(gpa, .{ .clocks = &.{.{ .name = "world", .fact = time, .rate = .{ .ticks = 2, .per = 3 } }}, .calendars = &.{persona}, .store = s.store() });
    defer t.deinit();
    _ = try t.every(clock, .{ .first = 3, .every = .{ .units = .{ .calendar = 0, .unit = 1, .n = 1 } }, .times = 20 }, 1);
    _ = try t.at(clock, 50, 2);
    var buf: [64]Tide.Due = undefined;
    _ = try t.elapse(clock, 13, &buf);
    const saved = try snapshot.write(&t, gpa);
    defer gpa.free(saved);
    const before = t.now(clock);
    var first: [64]Tide.Due = undefined;
    const a = try t.elapse(clock, 200, &buf);
    @memcpy(first[0..a.due.len], a.due);
    const after = t.now(clock);
    try std.testing.expect(after > before and a.due.len > 0);
    const report = try snapshot.restore(&t, saved);
    try std.testing.expectEqual(snapshot.Report{}, report);
    try std.testing.expectEqual(before, t.now(clock));
    try std.testing.expectEqual(@as(i64, @intCast(before)), s.int(time));
    const b = try t.elapse(clock, 200, &buf);
    try std.testing.expectEqual(after, t.now(clock));
    try std.testing.expectEqual(a.due.len, b.due.len);
    for (first[0..a.due.len], b.due) |x, y| {
        try std.testing.expectEqual(x.key, y.key);
        try std.testing.expectEqual(x.at, y.at);
        try std.testing.expectEqual(x.count, y.count);
    }
}

test "a restore matches clocks by name and reports what no longer fits" {
    var a = try Tide.init(gpa, .{ .clocks = &.{ .{ .name = "world" }, .{ .name = "dream" } }, .calendars = &.{persona} });
    defer a.deinit();
    _ = try a.at(.fromRaw(1), 9, 1);
    _ = try a.every(clock, .{ .first = 3, .every = .{ .units = .{ .calendar = 0, .unit = 1, .n = 1 } } }, 2);
    _ = try a.at(clock, 4, 3);
    const saved = try snapshot.write(&a, gpa);
    defer gpa.free(saved);
    var b = try Tide.init(gpa, .{ .clocks = &.{ .{ .name = "waking" }, .{ .name = "world" } } });
    defer b.deinit();
    const report = try snapshot.restore(&b, saved);
    try std.testing.expectEqual(snapshot.Report{ .dropped_clocks = 1, .missing_clocks = 1, .dropped_schedules = 2 }, report);
    var buf: [4]Tide.Due = undefined;
    const got = try b.advance(.fromRaw(1), 10, &buf);
    try std.testing.expectEqual(@as(usize, 1), got.due.len);
    try std.testing.expectEqual(@as(u64, 3), got.due[0].key);
}

test "every bound is a named error, and a refused snapshot changes nothing" {
    var t = try Tide.init(gpa, .{ .clocks = &.{.{ .name = "world" }}, .room = 2 });
    defer t.deinit();
    _ = try t.at(clock, 5, 1);
    _ = try t.after(clock, 6, 2);
    try std.testing.expectError(error.NoRoom, t.at(clock, 7, 3));
    try std.testing.expectError(error.BadRecurrence, t.every(clock, .{ .first = 0, .every = .{ .ticks = 0 } }, 4));
    try std.testing.expectError(error.BadRecurrence, t.every(clock, .{ .first = 0, .every = .{ .units = .{ .calendar = 0, .unit = 0, .n = 1 } } }, 4));
    var buf: [4]Tide.Due = undefined;
    try std.testing.expectError(error.ClockOverflow, t.advance(clock, Tide.max_tick + 1, &buf));
    try std.testing.expectError(error.UnknownClock, t.advance(.fromRaw(3), 1, &buf));
    try std.testing.expectError(error.BadRate, t.setRate(clock, .{ .ticks = 1, .per = 0 }));
    try std.testing.expectError(error.DuplicateName, Tide.init(gpa, .{ .clocks = &.{ .{ .name = "a" }, .{ .name = "a" } } }));
    const saved = try snapshot.write(&t, gpa);
    defer gpa.free(saved);
    try std.testing.expectError(error.BadSnapshot, snapshot.restore(&t, saved[0 .. saved.len - 1]));
    try std.testing.expectError(error.BadSnapshot, snapshot.restore(&t, "TIDESNAP"));
    const got = try t.advance(clock, 10, &buf);
    try std.testing.expectEqual(@as(usize, 2), got.due.len);
    try std.testing.expectEqual(@as(u64, 10), t.now(clock));
}

test "cancelled schedules never come due, and their room is taken again" {
    var t = try Tide.init(gpa, .{ .clocks = &.{.{ .name = "world" }}, .room = 1 });
    defer t.deinit();
    for (0..100) |i| {
        const tok = try t.at(clock, 5, i);
        try std.testing.expect(t.cancel(tok));
        try std.testing.expect(!t.cancel(tok));
    }
    _ = try t.at(clock, 5, 7);
    try std.testing.expectEqual(@as(u32, 1), t.cancelKey(7));
    var buf: [4]Tide.Due = undefined;
    try std.testing.expectEqual(@as(usize, 0), (try t.advance(clock, 10, &buf)).due.len);
}

test "the same advances give the same due, every time" {
    var runs: [2][32]u64 = undefined;
    for (&runs) |*run| {
        var t = try Tide.init(gpa, .{ .clocks = &.{.{ .name = "world", .rate = .{ .ticks = 5, .per = 7 } }}, .calendars = &.{persona} });
        defer t.deinit();
        _ = try t.every(clock, .{ .first = 1, .every = .{ .ticks = 3 } }, 1);
        _ = try t.every(clock, .{ .first = 1, .every = .{ .ticks = 3 } }, 2);
        _ = try t.every(clock, .{ .first = 2, .every = .{ .units = .{ .calendar = 0, .unit = 1, .n = 1 } }, .policy = .once }, 3);
        var buf: [32]Tide.Due = undefined;
        var n: usize = 0;
        for ([_]u64{ 3, 11, 0, 29, 2 }) |e| for ((try t.elapse(clock, e, buf[0 .. 32 - n])).due) |d| {
            run[n] = d.key * 1000 + d.at;
            n += 1;
        };
        @memset(run[n..], 0);
    }
    try std.testing.expectEqualSlices(u64, &runs[0], &runs[1]);
}

test "any bytes restore or are refused, and a refusal changes nothing" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var input: [512]u8 = undefined;
            const bytes = input[0..smith.sliceWithHash(&input, 0)];
            var t = try Tide.init(gpa, .{ .clocks = &.{.{ .name = "world" }}, .calendars = &.{persona}, .room = 8 });
            defer t.deinit();
            _ = try t.at(clock, 5, 1);
            _ = snapshot.restore(&t, bytes) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {
                    try std.testing.expectEqual(@as(u64, 0), t.now(clock));
                    return;
                },
            };
            var buf: [16]Tide.Due = undefined;
            var left: u64 = 100;
            while (left > 0) left = (try t.advance(clock, left, &buf)).left;
        }
    }.one, .{});
}
