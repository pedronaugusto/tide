//! A checked story's time: its `(calendar)` sections and the schedules its
//! tags declare, read into tide's block, every instant worked out from the
//! calendar it names. What only the whole shows (a calendar that does not
//! hold together, a time it never reaches, a schedule with no calendar) is
//! a problem with the place it is written; what a tag gets wrong alone its
//! judge has said, and the reader passes over it. Ids are the checker's
//! until the compile pass maps them to the compiled story's.

const std = @import("std");
const riverrun = @import("riverrun-compiler");
const tide = @import("tide");
const written = @import("written.zig");

const check = riverrun.check;
const sym = check.symbols;
const ast = riverrun.syntax.ast;
const Span = riverrun.syntax.Span;
const block = tide.block;
const Calendar = tide.Calendar;

const tagOf = written.tagOf;
const only = written.only;
const number = written.number;

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
    for (checked.sections, 0..) |s, i| if (written.isCalendar(s)) try r.calendarOf(sym.idOf(sym.SectionId, i));
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

const Cal = struct {
    out: block.Cal,
    section: sym.SectionId,
    /// Null when the calendar does not hold together: its instants cannot be worked out.
    calendar: ?Calendar,
};

const What = @FieldType(block.Derived, "what");

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
    /// A calendar was refused, here or by a judge: what would have stood on it says nothing more.
    refused: bool = false,

    fn problem(r: *Reader, span: Span, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
        r.refused = true;
        try r.problems.append(r.a, .{ .span = span, .message = try r.a.print(fmt, args) });
    }

    // What a judge refused, which it said: the reader passes over it.
    fn judged(r: *Reader, comptime T: type) ?T {
        r.refused = true;
        return null;
    }

    // A fact the calendar section declares.
    fn kept(r: *const Reader, section: sym.SectionId, name: []const u8) ?u16 {
        for (r.checked.facts, 0..) |f, i| if (f.by != null and f.by.?.eql(section) and std.mem.eql(u8, f.name, name)) return @intCast(i); // safe: facts are at most 4096
        return null;
    }

    fn clockOf(r: *const Reader, module: sym.ModuleId, name: []const u8) ?u8 {
        const named = r.checked.value_names.find(module, name) orelse return null;
        if (named != .fact) return null;
        for (r.clocks.items, 0..) |c, i| if (named.fact.eql(.fromRaw(c))) return @intCast(i); // safe: at most max_clocks
        return null;
    }

    fn calendarOf(r: *Reader, id: sym.SectionId) error{OutOfMemory}!void {
        const s = r.checked.sections[id.raw()];
        if (r.cals.items.len == block.max_calendars) return r.problem(s.node.name.span, "a story holds at most {d} calendars", .{block.max_calendars});
        var c: Cal = .{ .section = id, .calendar = null, .out = .{ .section = id.raw(), .clock = 0, .start = 0, .units = &.{}, .cycles = &.{} } };
        const clock = tagOf(s.node.tags, "clock") orelse return r.problem(s.node.name.span, "a calendar reads a clock: `[clock …]` and a `(clock)` fact", .{});
        c.out.clock = r.clockOf(s.module, only(clock)) orelse {
            r.refused = true;
            return;
        };
        if (tagOf(s.node.tags, "start")) |t| c.out.start = number(only(t)) orelse return r.problem(t.key.span, "`start` is a number of ticks", .{});
        var units: std.ArrayList(block.Unit) = .empty;
        var cycles: std.ArrayList(block.Cycle) = .empty;
        var whole = true;
        for (s.parts) |p| switch (written.what(p.node)) {
            .unit => {
                if (units.items.len == tide.calendar.max_units) return r.problem(p.node.name.span, "a calendar holds at most {d} units", .{tide.calendar.max_units});
                try units.append(r.a, try r.unitOf(id, p));
            },
            .cycle => {
                if (cycles.items.len == tide.calendar.max_cycles) return r.problem(p.node.name.span, "a calendar holds at most {d} cycles", .{tide.calendar.max_cycles});
                const y = try r.cycleOf(id, p, units.items) orelse {
                    whole = false;
                    continue;
                };
                try cycles.append(r.a, y);
            },
            .derived => {},
            .other => {
                try r.problem(p.node.name.span, "a calendar's part is a unit (`size`), a cycle (`cycle`) or a time fact it keeps (`until`, `since`, `drift`)", .{});
                whole = false;
            },
        };
        if (!whole) return;
        c.out.units = units.items;
        c.out.cycles = cycles.items;
        c.calendar = try r.build(s, c.out);
        try r.cals.append(r.a, c);
    }

    // The calendar itself, to work out instants and to know it holds together.
    fn build(r: *Reader, s: sym.Section, out: block.Cal) error{OutOfMemory}!?Calendar {
        const units = try r.a.alloc(tide.calendar.Unit, out.units.len);
        for (units, out.units, 0..) |*u, o, i| u.* = .{ .name = o.name, .size = switch (o.size) {
            .fixed => |f| .{ .fixed = f },
            .cycle => |sizes| .{ .cycle = sizes },
        }, .names = written.names(written.nth(s.node, .unit, i).?) };
        const cycles = try r.a.alloc(tide.calendar.Cycle, out.cycles.len);
        for (cycles, out.cycles, 0..) |*y, o, j| y.* = .{ .name = o.name, .unit = o.unit, .length = o.length, .offset = o.offset, .names = written.names(written.nth(s.node, .cycle, j).?) };
        return Calendar.init(r.gpa, .{ .name = s.name, .units = units, .cycles = cycles, .start = out.start }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try r.problem(s.node.name.span, "the calendar does not hold together: {s}", .{describe(err)});
                return null;
            },
        };
    }

    fn unitOf(r: *Reader, id: sym.SectionId, p: sym.Part) error{OutOfMemory}!block.Unit {
        var u: block.Unit = .{ .name = p.name, .size = .{ .fixed = 1 } };
        const size = tagOf(p.node.tags, "size").?;
        if (size.values.len == 1) {
            u.size = .{ .fixed = number(size.values[0]) orelse 0 };
        } else {
            const sizes = try r.a.alloc(u32, size.values.len);
            for (sizes, size.values) |*n, v| n.* = std.math.cast(u32, number(v) orelse 0) orelse 0;
            u.size = .{ .cycle = sizes };
        }
        if (tagOf(p.node.tags, "place")) |t| u.place = r.kept(id, only(t)) orelse block.none16;
        if (tagOf(p.node.tags, "count")) |t| u.count = r.kept(id, only(t)) orelse block.none16;
        return u;
    }

    // A cycle's length is its `length`, else how many `names` its places have.
    fn cycleOf(r: *Reader, id: sym.SectionId, p: sym.Part, units: []const block.Unit) error{OutOfMemory}!?block.Cycle {
        const over = tagOf(p.node.tags, "cycle").?;
        var y: block.Cycle = .{ .name = p.name, .unit = 0, .length = 0, .offset = 0 };
        y.unit = unitNamed(units, only(over)) orelse return r.judged(block.Cycle);
        if (tagOf(p.node.tags, "length")) |t| {
            y.length = std.math.cast(u32, number(only(t)) orelse 0) orelse 0;
        } else {
            y.length = std.math.cast(u32, written.names(p.node).len) orelse 0;
            if (y.length == 0) {
                try r.problem(p.node.name.span, "a cycle has a `length`, or the `names` of its places", .{});
                return null;
            }
        }
        if (tagOf(p.node.tags, "offset")) |t| y.offset = std.math.cast(u32, number(only(t)) orelse 0) orelse 0;
        if (tagOf(p.node.tags, "place")) |t| y.place = r.kept(id, only(t)) orelse block.none16;
        return y;
    }

    fn derivedOf(r: *Reader, ci: u8) error{OutOfMemory}!void {
        const c = &r.cals.items[ci];
        const s = r.checked.sections[c.section.raw()];
        for (s.parts) |p| if (written.what(p.node) == .derived) {
            if (r.derived.items.len == block.max_derived) return r.problem(p.node.name.span, "a story keeps at most {d} time facts", .{block.max_derived});
            // the calendar declares it, unless the story declares the name itself, which the checker said
            const id = r.kept(c.section, p.name) orelse continue;
            if (try r.derivation(ci, p)) |what| try r.derived.append(r.a, .{ .fact = id, .what = what });
        };
    }

    fn derivation(r: *Reader, ci: u8, p: sym.Part) error{OutOfMemory}!?What {
        const c = r.cals.items[ci];
        const tags = p.node.tags;
        if (tagOf(tags, "drift")) |t| {
            const b = r.clockOf(r.checked.sections[c.section.raw()].module, only(t)) orelse return r.judged(What);
            const per = perTicks(c, tags) orelse return r.judged(What);
            return .{ .drift = .{ .a = c.out.clock, .b = b, .per = per } };
        }
        const until = tagOf(tags, "until");
        const at = try r.instant(ci, until orelse tagOf(tags, "since").?) orelse return null;
        const per = r.perOf(ci, tags) orelse return r.judged(What);
        if (until != null) return .{ .until = .{ .clock = c.out.clock, .at = at, .per = per } };
        return .{ .since = .{ .clock = c.out.clock, .at = at, .per = per } };
    }

    // `per day` or `per 4`: counted in a unit of the calendar, or in ticks; one tick when unsaid.
    fn perOf(r: *const Reader, ci: u8, tags: []const ast.Tag) ?block.Per {
        const t = tagOf(tags, "per") orelse return .{ .ticks = 1 };
        if (number(only(t))) |n| return if (n == 0) null else .{ .ticks = n };
        const u = unitNamed(r.cals.items[ci].out.units, only(t)) orelse return null;
        return .{ .unit = .{ .calendar = ci, .unit = u } };
    }

    // The first tick tag `t`'s words name on calendar `ci`: the first at or after its count's start where every
    // place it names holds.
    fn instant(r: *Reader, ci: u8, t: *const ast.Tag) error{OutOfMemory}!?u64 {
        const c = r.cals.items[ci];
        const cal = &(c.calendar orelse return null);
        const words = switch (try written.instant(r.a, r.checked.sections[c.section.raw()].node, t.values)) {
            .instant => |i| i,
            .problem => return r.judged(u64),
        };
        var base: u64 = 0;
        if (words.count) |count| base = cal.tickOf(count.unit, count.n) orelse {
            try r.problem(t.key.span, "{s} {d} is before the calendar's start or past what a clock counts", .{ c.out.units[count.unit].name, count.n });
            return null;
        };
        if (words.len == 0) return base;
        return cal.next(base, words.places()) catch {
            try r.problem(t.key.span, "the calendar has no such time", .{});
            return null;
        };
    }

    fn scheduleOf(r: *Reader, target: Target, tags: []const ast.Tag, span: Span) error{OutOfMemory}!void {
        const at = tagOf(tags, "at");
        const every = tagOf(tags, "every");
        if (at == null and every == null) return;
        if (target == .part) switch (r.checked.sections[target.part.section.raw()].kind) {
            .pool, .rules => return r.problem(span, "a pool's candidate or a rule comes due with its section: schedule the section", .{}),
            .scene, .other => {},
        };
        if (r.schedules.items.len == block.max_schedules) return r.problem(span, "a story declares at most {d} schedules", .{block.max_schedules});
        const ci = try r.calendarFor(tags, span) orelse return;
        var s: block.Schedule = .{ .section = 0, .clock = r.cals.items[ci].out.clock, .first = 0 };
        if (at) |t| s.first = try r.instant(ci, t) orelse return;
        if (every) |t| s.every = r.everyOf(ci, tags, t) orelse return;
        if (tagOf(tags, "times")) |t| s.times = number(only(t));
        if (tagOf(tags, "policy")) |t| s.policy = if (std.mem.eql(u8, only(t), "once")) .once else .each;
        if (s.every) |e| {
            const cal = if (r.cals.items[ci].calendar) |*c| c else return; // a calendar that does not hold together said why
            _ = tide.schedule.firstDue(.{ .first = s.first, .every = e, .times = s.times, .policy = s.policy }, cal) catch |err| return r.problem(span, "{s}", .{switch (err) {
                error.NoStep => "a schedule's step moves time: give `interval` at least 1",
                error.NoTimes => "`times 0` never comes due: give at least 1, or leave `times` out for ever",
                error.PastTheClock => "this schedule first comes due past what a clock counts",
            }});
        }
        try r.schedules.append(r.a, s);
        try r.targets.append(r.a, target);
    }

    fn everyOf(r: *const Reader, ci: u8, tags: []const ast.Tag, t: *const ast.Tag) ?tide.schedule.Every {
        const c = r.cals.items[ci].out;
        const interval = if (tagOf(tags, "interval")) |i| number(only(i)) orelse 1 else 1;
        if (unitNamed(c.units, only(t))) |u| return .{ .units = .{ .calendar = ci, .unit = u, .n = interval } };
        for (c.cycles) |y| if (std.mem.eql(u8, y.name, only(t))) {
            return .{ .units = .{ .calendar = ci, .unit = y.unit, .n = std.math.mul(u64, y.length, interval) catch return null } };
        };
        return null;
    }

    // The calendar a schedule means, by its place among those read; what leaves it none or several is said here.
    fn calendarFor(r: *Reader, tags: []const ast.Tag, span: Span) error{OutOfMemory}!?u8 {
        switch (written.which(r.checked.sections, tags)) {
            .one => |i| {
                for (r.cals.items, 0..) |c, k| if (c.section.eql(.fromRaw(std.math.cast(@TypeOf(c.section.raw()), i) orelse continue))) return @intCast(k); // safe: at most max_calendars
                return null; // a calendar refused, which said why
            },
            .named_none => return null,
            .several => try r.problem(span, "these times are of more than one calendar: say which, `calendar name`", .{}),
            .none => try r.problem(span, "a schedule needs a calendar: the story declares none", .{}),
            .unsaid => if (!r.refused) try r.problem(span, "say which calendar: `calendar name`", .{}),
        }
        return null;
    }
};

// A drift is counted in ticks, so `per` names a unit of fixed size.
fn perTicks(c: Cal, tags: []const ast.Tag) ?u64 {
    const t = tagOf(tags, "per") orelse return 1;
    if (number(only(t))) |n| return if (n == 0) null else n;
    const u = unitNamed(c.out.units, only(t)) orelse return null;
    var ticks: u64 = 1;
    for (c.out.units[0 .. @as(usize, u) + 1]) |unit| switch (unit.size) {
        .fixed => |n| ticks = std.math.mul(u64, ticks, n) catch return null,
        .cycle => return null,
    };
    return ticks;
}

fn unitNamed(units: []const block.Unit, name: []const u8) ?u8 {
    for (units, 0..) |u, i| if (std.mem.eql(u8, u.name, name)) return @intCast(i); // safe: at most max_units
    return null;
}

fn describe(err: tide.calendar.Error) []const u8 {
    return switch (err) {
        error.EmptyName => "a unit or cycle has no name",
        error.EmptySize => "a unit has a size of zero",
        error.NamesDoNotFit => "a unit's names are not one for each of its places in the next unit, or a cycle's for each of its length",
        error.BadCycle => "a cycle is of length zero, or starts past its end",
        error.CalendarTooLarge => "its sizes overflow what a clock counts",
        else => @errorName(err),
    };
}
