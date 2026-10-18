//! A checked story's time: its `(calendar)` sections and the schedules its
//! tags declare, read into tide's block, every instant worked out from the
//! calendar it names. What does not hold together is a problem with the
//! place it is written, for the checker to report; ids are the checker's
//! until the compile pass maps them to the compiled story's.

const std = @import("std");
const riverrun = @import("riverrun-compiler");
const tide = @import("tide");

const check = riverrun.check;
const sym = check.symbols;
const ast = riverrun.syntax.ast;
const Span = riverrun.syntax.Span;
const block = tide.block;
const Calendar = tide.Calendar;
const Want = tide.calendar.Want;

pub const Problem = struct { span: Span, message: []const u8 };

/// What a schedule's tags stand on: a section, or a part of one.
pub const Target = union(enum) { section: sym.SectionId, part: sym.PartRef };

pub const Read = struct {
    /// In the checker's ids: facts and sections as `check.symbols` numbers them.
    plan: block.Plan,
    /// The place of each of the plan's schedules.
    targets: []const Target,
    problems: []const Problem,
};

/// Reads `checked`'s time; lists are on `arena`, the calendars built to work out instants on `gpa` and freed.
pub fn read(gpa: std.mem.Allocator, arena: std.mem.Allocator, checked: *const check.Checked) error{OutOfMemory}!Read {
    var r: Reader = .{ .gpa = gpa, .a = arena, .checked = checked };
    defer for (r.cals.items) |*c| if (c.calendar) |*cal| cal.deinit(gpa);
    for (checked.facts, 0..) |f, i| if (f.clock) try r.clocks.append(arena, @intCast(i)); // safe: facts are at most 4096
    for (checked.sections, 0..) |s, i| if (isCalendar(s)) try r.calendarOf(sym.idOf(sym.SectionId, i));
    for (r.cals.items, 0..) |_, i| try r.derivedOf(@intCast(i)); // safe: at most max_calendars
    for (checked.sections, 0..) |s, i| {
        const id = sym.idOf(sym.SectionId, i);
        try r.scheduleOf(.{ .section = id }, s.node.tags, s.node.name.span);
        for (s.parts, 0..) |p, k| try r.scheduleOf(.{ .part = .{ .section = id, .index = @intCast(k) } }, p.node.tags, p.node.name.span); // safe: a section's parts number at most a u16
    }
    const cals = try arena.alloc(block.Cal, r.cals.items.len);
    for (cals, r.cals.items) |*out, c| out.* = c.out;
    return .{
        .plan = .{ .clocks = r.clocks.items, .calendars = cals, .derived = r.derived.items, .schedules = r.schedules.items },
        .targets = r.targets.items,
        .problems = r.problems.items,
    };
}

fn isCalendar(s: sym.Section) bool {
    return s.kind == .other and std.mem.eql(u8, s.kind.other, "calendar");
}

const Cal = struct {
    out: block.Cal,
    section: sym.SectionId,
    /// Null when the calendar does not hold together: its instants cannot be worked out.
    calendar: ?Calendar,
};

const Reader = struct {
    gpa: std.mem.Allocator,
    a: std.mem.Allocator,
    checked: *const check.Checked,
    problems: std.ArrayList(Problem) = .empty,
    clocks: std.ArrayList(u16) = .empty,
    cals: std.ArrayList(Cal) = .empty,
    derived: std.ArrayList(block.Derived) = .empty,
    schedules: std.ArrayList(block.Schedule) = .empty,
    targets: std.ArrayList(Target) = .empty,
    /// A calendar was refused: what would have stood on it says nothing more.
    refused: bool = false,

    fn problem(r: *Reader, span: Span, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
        try r.problems.append(r.a, .{ .span = span, .message = try r.a.print(fmt, args) });
    }

    fn fact(r: *const Reader, name: []const u8) ?sym.FactId {
        return r.checked.fact(name);
    }

    fn clockOf(r: *const Reader, name: []const u8) ?u8 {
        const id = r.fact(name) orelse return null;
        for (r.clocks.items, 0..) |c, i| if (c == id.raw()) return @intCast(i); // safe: at most max_clocks
        return null;
    }

    // The values of a `one of` fact, which name a unit's or a cycle's places.
    fn values(r: *const Reader, id: sym.FactId) ?[]const []const u8 {
        const t = r.checked.facts[id.raw()].type;
        if (t != .one_of) return null;
        return r.checked.enums[t.one_of.raw()].values;
    }

    fn calendarOf(r: *Reader, id: sym.SectionId) error{OutOfMemory}!void {
        const s = r.checked.sections[id.raw()];
        const before = r.problems.items.len;
        defer if (r.problems.items.len > before) {
            r.refused = true;
        };
        if (r.cals.items.len == block.max_calendars) return r.problem(s.node.name.span, "a story holds at most {d} calendars", .{block.max_calendars});
        var c: Cal = .{ .section = id, .calendar = null, .out = .{ .section = id.raw(), .clock = 0, .start = 0, .units = &.{}, .cycles = &.{} } };
        const clock = tagOf(s.node.tags, "clock") orelse return r.problem(s.node.name.span, "a calendar reads a clock: `# clock` and a `(clock)` fact", .{});
        c.out.clock = r.clockOf(only(clock)) orelse return r.problem(clock.key.span, "`{s}` is not a `(clock)` fact", .{only(clock)});
        if (tagOf(s.node.tags, "start")) |t| c.out.start = number(only(t)) orelse return r.problem(t.key.span, "`start` is a number of ticks", .{});
        var units: std.ArrayList(block.Unit) = .empty;
        var cycles: std.ArrayList(block.Cycle) = .empty;
        var names: [tide.calendar.max_units][]const []const u8 = undefined;
        for (s.parts) |p| if (tagOf(p.node.tags, "size") != null) {
            if (units.items.len == tide.calendar.max_units) return r.problem(p.node.name.span, "a calendar holds at most {d} units", .{tide.calendar.max_units});
            names[units.items.len] = &.{};
            try units.append(r.a, try r.unitOf(p, &names[units.items.len]) orelse return);
        };
        for (s.parts) |p| if (tagOf(p.node.tags, "cycle") != null) {
            if (cycles.items.len == tide.calendar.max_cycles) return r.problem(p.node.name.span, "a calendar holds at most {d} cycles", .{tide.calendar.max_cycles});
            try cycles.append(r.a, try r.cycleOf(p, units.items) orelse return);
        };
        for (s.parts) |p| if (!isUnit(p) and !isCycle(p) and !isDerived(p)) {
            try r.problem(p.node.name.span, "a calendar's part is a unit (`size`), a cycle (`cycle`) or a time fact it keeps (`until`, `since`, `drift`)", .{});
        };
        c.out.units = units.items;
        c.out.cycles = cycles.items;
        c.calendar = try r.build(s, c.out, names[0..units.items.len]);
        try r.cals.append(r.a, c);
    }

    // The calendar itself, to work out instants and to know it holds together.
    fn build(r: *Reader, s: sym.Section, out: block.Cal, unit_names: []const []const []const u8) error{OutOfMemory}!?Calendar {
        const units = try r.a.alloc(tide.calendar.Unit, out.units.len);
        for (units, out.units, unit_names) |*u, o, n| u.* = .{ .name = o.name, .size = switch (o.size) {
            .fixed => |f| .{ .fixed = f },
            .cycle => |sizes| .{ .cycle = sizes },
        }, .names = n };
        const cycles = try r.a.alloc(tide.calendar.Cycle, out.cycles.len);
        for (cycles, out.cycles) |*y, o| y.* = .{ .name = o.name, .unit = o.unit, .length = o.length, .offset = o.offset, .names = if (o.place != block.none16) r.values(.fromRaw(o.place)).? else &.{} };
        return Calendar.init(r.gpa, .{ .name = s.name, .units = units, .cycles = cycles, .start = out.start }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try r.problem(s.node.name.span, "the calendar does not hold together: {s}", .{describe(err)});
                return null;
            },
        };
    }

    fn unitOf(r: *Reader, p: sym.Part, names: *[]const []const u8) error{OutOfMemory}!?block.Unit {
        var u: block.Unit = .{ .name = p.name, .size = .{ .fixed = 1 } };
        const size = tagOf(p.node.tags, "size").?;
        if (size.values.len == 1) {
            u.size = .{ .fixed = number(size.values[0]) orelse 0 };
        } else {
            const sizes = try r.a.alloc(u32, size.values.len);
            for (sizes, size.values) |*n, v| n.* = std.math.cast(u32, number(v) orelse 0) orelse 0;
            u.size = .{ .cycle = sizes };
        }
        if (tagOf(p.node.tags, "place")) |t| {
            const id = try r.placeFact(t) orelse return null;
            names.* = r.values(id).?;
            u.place = id.raw();
        }
        if (tagOf(p.node.tags, "count")) |t| {
            const id = r.fact(only(t)) orelse {
                try r.missing(t, "an int");
                return null;
            };
            if (r.checked.facts[id.raw()].type != .int) {
                try r.wrong(t, "an int");
                return null;
            }
            u.count = id.raw();
        }
        return u;
    }

    // The `one of` fact a `place` tag names, whose values name the places.
    fn placeFact(r: *Reader, t: *const ast.Tag) error{OutOfMemory}!?sym.FactId {
        const id = r.fact(only(t)) orelse {
            try r.missing(t, "a `one of`");
            return null;
        };
        if (r.values(id) == null) {
            try r.wrong(t, "a `one of`, whose values name the places,");
            return null;
        }
        return id;
    }

    fn cycleOf(r: *Reader, p: sym.Part, units: []const block.Unit) error{OutOfMemory}!?block.Cycle {
        const over = tagOf(p.node.tags, "cycle").?;
        var y: block.Cycle = .{ .name = p.name, .unit = 0, .length = 0, .offset = 0 };
        y.unit = unitNamed(units, only(over)) orelse {
            try r.problem(over.key.span, "`{s}` is not a unit of this calendar", .{only(over)});
            return null;
        };
        const length = tagOf(p.node.tags, "length") orelse {
            try r.problem(p.node.name.span, "a cycle has a `length`", .{});
            return null;
        };
        y.length = std.math.cast(u32, number(only(length)) orelse 0) orelse 0;
        if (tagOf(p.node.tags, "offset")) |t| y.offset = std.math.cast(u32, number(only(t)) orelse 0) orelse 0;
        if (tagOf(p.node.tags, "place")) |t| y.place = (try r.placeFact(t) orelse return null).raw();
        return y;
    }

    fn missing(r: *Reader, t: *const ast.Tag, what: []const u8) error{OutOfMemory}!void {
        try r.problem(t.key.span, "nothing is called `{s}`: `{s}` names {s} fact", .{ only(t), t.key.text, what });
    }

    fn wrong(r: *Reader, t: *const ast.Tag, what: []const u8) error{OutOfMemory}!void {
        try r.problem(t.key.span, "`{s}` names {s} fact, and `{s}` is not one", .{ t.key.text, what, only(t) });
    }

    fn derivedOf(r: *Reader, ci: u8) error{OutOfMemory}!void {
        const c = &r.cals.items[ci];
        const s = r.checked.sections[c.section.raw()];
        for (s.parts) |p| if (isDerived(p)) {
            if (r.derived.items.len == block.max_derived) return r.problem(p.node.name.span, "a story keeps at most {d} time facts", .{block.max_derived});
            const id = r.fact(p.name) orelse {
                try r.problem(p.node.name.span, "`{s}` keeps a time: declare it an int fact", .{p.name});
                continue;
            };
            if (r.checked.facts[id.raw()].type != .int) {
                try r.problem(p.node.name.span, "`{s}` keeps a time, so it is an int", .{p.name});
                continue;
            }
            if (try r.derivation(ci, p)) |what| try r.derived.append(r.a, .{ .fact = id.raw(), .what = what });
        };
    }

    fn derivation(r: *Reader, ci: u8, p: sym.Part) error{OutOfMemory}!?@FieldType(block.Derived, "what") {
        const c = r.cals.items[ci];
        const tags = p.node.tags;
        if (tagOf(tags, "drift")) |t| {
            const b = r.clockOf(only(t)) orelse {
                try r.problem(t.key.span, "`{s}` is not a `(clock)` fact", .{only(t)});
                return null;
            };
            const per = try r.perTicks(c, tags) orelse return null;
            return .{ .drift = .{ .a = c.out.clock, .b = b, .per = per } };
        }
        const at = try r.instant(ci, tags, p.node.name.span) orelse return null;
        const per = try r.perOf(ci, tags) orelse return null;
        if (tagOf(tags, "until") != null) return .{ .until = .{ .clock = c.out.clock, .at = at, .per = per } };
        return .{ .since = .{ .clock = c.out.clock, .at = at, .per = per } };
    }

    // `per day` or `per 4`: counted in a unit of the calendar, or in ticks; one tick when unsaid.
    fn perOf(r: *Reader, ci: u8, tags: []const ast.Tag) error{OutOfMemory}!?block.Per {
        const t = tagOf(tags, "per") orelse return .{ .ticks = 1 };
        if (number(only(t))) |n| return if (n == 0) null else .{ .ticks = n };
        const u = unitNamed(r.cals.items[ci].out.units, only(t)) orelse {
            try r.problem(t.key.span, "`{s}` is not a unit of this calendar, nor a number of ticks", .{only(t)});
            return null;
        };
        return .{ .unit = .{ .calendar = ci, .unit = u } };
    }

    // A drift is counted in ticks, so `per` names a unit of fixed size.
    fn perTicks(r: *Reader, c: Cal, tags: []const ast.Tag) error{OutOfMemory}!?u64 {
        const t = tagOf(tags, "per") orelse return 1;
        if (number(only(t))) |n| return if (n == 0) null else n;
        const u = unitNamed(c.out.units, only(t)) orelse {
            try r.problem(t.key.span, "`{s}` is not a unit of this calendar, nor a number of ticks", .{only(t)});
            return null;
        };
        var ticks: u64 = 1;
        for (c.out.units[0 .. @as(usize, u) + 1]) |unit| switch (unit.size) {
            .fixed => |n| ticks = std.math.mul(u64, ticks, n) catch return null,
            .cycle => {
                try r.problem(t.key.span, "a drift is counted in ticks: `{s}` has no fixed size", .{only(t)});
                return null;
            },
        };
        return ticks;
    }

    // The first tick the tags name on calendar `ci`: a count (`day 34`) and places (`weekday sunday`, `slot
    // evening`), the first at or after the count's start where every place holds.
    fn instant(r: *Reader, ci: u8, tags: []const ast.Tag, span: Span) error{OutOfMemory}!?u64 {
        const c = r.cals.items[ci];
        const cal = &(c.calendar orelse return null);
        var wants: [tide.calendar.max_units + tide.calendar.max_cycles]Want = undefined;
        var n: usize = 0;
        var base: u64 = 0;
        for (tags) |*t| {
            if (r.wantOf(c, t)) |w| {
                wants[n] = w;
                n += 1;
            } else for (c.out.units, 0..) |u, level| if (u.count != block.none16 and keyIs(r, u.count, t)) {
                const count = number(only(t)) orelse 0;
                base = cal.tickOf(level, count) orelse {
                    try r.problem(t.key.span, "{s} {d} is before the calendar's start or past what a clock counts", .{ t.key.text, count });
                    return null;
                };
            };
        }
        if (n == 0) return base;
        return cal.next(base, wants[0..n]) catch {
            try r.problem(span, "the calendar has no such time", .{});
            return null;
        };
    }

    // A place a tag names on this calendar: `slot evening` for a unit's place, `weekday sunday` for a cycle's.
    fn wantOf(r: *const Reader, c: Cal, t: *const ast.Tag) ?Want {
        for (c.out.units, 0..) |u, level| if (u.place != block.none16 and keyIs(r, u.place, t)) {
            return .{ .what = .{ .place = @intCast(level) }, .value = indexOf(r.values(.fromRaw(u.place)).?, only(t)) }; // safe: at most max_units
        };
        for (c.out.cycles, 0..) |y, j| if (y.place != block.none16 and keyIs(r, y.place, t)) {
            return .{ .what = .{ .cycle = @intCast(j) }, .value = indexOf(r.values(.fromRaw(y.place)).?, only(t)) }; // safe: at most max_cycles
        };
        return null;
    }

    fn scheduleOf(r: *Reader, target: Target, tags: []const ast.Tag, span: Span) error{OutOfMemory}!void {
        const at = tagOf(tags, "at");
        const every = tagOf(tags, "every");
        if (at == null and every == null) return;
        if (at != null and every != null) return r.problem(span, "a schedule is one time (`at`) or a recurrence (`every`), not both", .{});
        if (r.schedules.items.len == block.max_schedules) return r.problem(span, "a story declares at most {d} schedules", .{block.max_schedules});
        const ci = try r.calendarFor(tags, span) orelse return;
        var s: block.Schedule = .{ .section = 0, .clock = r.cals.items[ci].out.clock, .first = try r.instant(ci, tags, span) orelse return };
        if (every) |t| s.every = try r.everyOf(ci, tags, t) orelse return;
        if (tagOf(tags, "times")) |t| s.times = number(only(t));
        if (tagOf(tags, "policy")) |t| s.policy = if (std.mem.eql(u8, only(t), "once")) .once else .each;
        try r.schedules.append(r.a, s);
        try r.targets.append(r.a, target);
    }

    fn everyOf(r: *Reader, ci: u8, tags: []const ast.Tag, t: *const ast.Tag) error{OutOfMemory}!?tide.schedule.Every {
        const c = r.cals.items[ci].out;
        const interval = if (tagOf(tags, "interval")) |i| number(only(i)) orelse 1 else 1;
        if (unitNamed(c.units, only(t))) |u| return .{ .units = .{ .calendar = ci, .unit = u, .n = interval } };
        for (c.cycles) |y| if (std.mem.eql(u8, y.name, only(t))) {
            return .{ .units = .{ .calendar = ci, .unit = y.unit, .n = std.math.mul(u64, y.length, interval) catch return null } };
        };
        try r.problem(t.key.span, "`{s}` is not a unit or a cycle of this calendar", .{only(t)});
        return null;
    }

    // The calendar a schedule means: the one `calendar` names, else the one whose facts its tags name, else
    // the only one.
    fn calendarFor(r: *Reader, tags: []const ast.Tag, span: Span) error{OutOfMemory}!?u8 {
        if (tagOf(tags, "calendar")) |t| {
            for (r.cals.items, 0..) |c, i| if (std.mem.eql(u8, r.checked.sections[c.section.raw()].name, only(t))) return @intCast(i); // safe: at most max_calendars
            try r.problem(t.key.span, "`{s}` is not a calendar", .{only(t)});
            return null;
        }
        var found: ?u8 = null;
        for (r.cals.items, 0..) |c, i| for (tags) |*t| if (r.wantOf(c, t) != null or countsWith(r, c, t)) {
            if (found != null and found.? != i) {
                try r.problem(span, "these times are of more than one calendar: say which, `calendar name`", .{});
                return null;
            }
            found = @intCast(i); // safe: at most max_calendars
        };
        if (found) |f| return f;
        if (r.cals.items.len == 1) return 0;
        if (r.refused) return null;
        if (r.cals.items.len == 0) {
            try r.problem(span, "a schedule needs a calendar: the story declares none", .{});
        } else try r.problem(span, "say which calendar: `calendar name`", .{});
        return null;
    }
};

fn countsWith(r: *const Reader, c: Cal, t: *const ast.Tag) bool {
    for (c.out.units) |u| if (u.count != block.none16 and keyIs(r, u.count, t)) return true;
    return false;
}

// Whether tag `t`'s key is the fact numbered `raw`.
fn keyIs(r: *const Reader, raw: u16, t: *const ast.Tag) bool {
    return std.mem.eql(u8, r.checked.facts[raw].name, t.key.text);
}

fn isUnit(p: sym.Part) bool {
    return tagOf(p.node.tags, "size") != null;
}

fn isCycle(p: sym.Part) bool {
    return tagOf(p.node.tags, "cycle") != null;
}

fn isDerived(p: sym.Part) bool {
    return tagOf(p.node.tags, "until") != null or tagOf(p.node.tags, "since") != null or tagOf(p.node.tags, "drift") != null;
}

fn unitNamed(units: []const block.Unit, name: []const u8) ?u8 {
    for (units, 0..) |u, i| if (std.mem.eql(u8, u.name, name)) return @intCast(i); // safe: at most max_units
    return null;
}

fn tagOf(tags: []const ast.Tag, key: []const u8) ?*const ast.Tag {
    for (tags) |*t| if (std.mem.eql(u8, t.key.text, key)) return t;
    return null;
}

// A tag's one value; the checker holds a key to its count, so a missing one reads as empty.
fn only(t: *const ast.Tag) []const u8 {
    return if (t.values.len > 0) t.values[0] else "";
}

fn number(s: []const u8) ?u64 {
    return std.fmt.parseInt(u64, s, 10) catch null;
}

// The checker holds a place's value to its fact's values, so it is found.
fn indexOf(values: []const []const u8, v: []const u8) u64 {
    for (values, 0..) |w, i| if (std.mem.eql(u8, w, v)) return i;
    return 0;
}

fn describe(err: tide.calendar.Error) []const u8 {
    return switch (err) {
        error.EmptyName => "a unit or cycle has no name",
        error.EmptySize => "a unit has a size of zero",
        error.NamesDoNotFit => "a place fact's values do not number the places of the next unit",
        error.BadCycle => "a cycle is of length zero, or starts past its end",
        error.CalendarTooLarge => "its sizes overflow what a clock counts",
        else => @errorName(err),
    };
}
