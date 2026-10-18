//! A calendar as its section is written: its units, cycles and time facts,
//! read from its parts' tags alone, and an instant's words read against
//! it. What a calendar declares, what tide's judges hold a tag to and what
//! the reader works out all start here, so the three agree.
//!
//!     == school (calendar)    # clock turn · scope time
//!     = slot       # size 1 · place slot · names morning, noon, afternoon, evening
//!     = day        # size 4 · count day
//!     = week       # cycle day · place weekday · names monday, …, sunday
//!     = days_left  # until day 34 · per day
//!
//! An instant is words: a count (`day 34`) and places, each a place fact
//! and its value (`weekday sunday`) or a place's name alone where no other
//! place of the calendar takes it (`sunday evening`).

const std = @import("std");
const riverrun = @import("riverrun-compiler");
const tide = @import("tide");

const ast = riverrun.syntax.ast;
const sym = riverrun.check.symbols;
const Want = tide.calendar.Want;

/// The kind of section a calendar is.
pub const kind = "calendar";

pub fn isCalendar(s: sym.Section) bool {
    return s.kind == .other and std.mem.eql(u8, s.kind.other, kind);
}

pub fn tagOf(tags: []const ast.Tag, key: []const u8) ?*const ast.Tag {
    for (tags) |*t| if (std.mem.eql(u8, t.key.text, key)) return t;
    return null;
}

/// A tag's one value; the checker holds a key to its count, so a missing one reads as empty.
pub fn only(t: *const ast.Tag) []const u8 {
    return if (t.values.len > 0) t.values[0] else "";
}

pub fn number(s: []const u8) ?u64 {
    return std.fmt.parseInt(u64, s, 10) catch null;
}

/// What a calendar's part is, by its tags.
pub const What = enum {
    /// `size`: a unit, nested in the next.
    unit,
    /// `cycle`: a cycle round a unit.
    cycle,
    /// `until`, `since` or `drift`: a time fact the calendar keeps, named by the part.
    derived,
    other,
};

pub fn what(p: *const ast.Subsection) What {
    if (tagOf(p.tags, "size") != null) return .unit;
    if (tagOf(p.tags, "cycle") != null) return .cycle;
    if (tagOf(p.tags, "until") != null or tagOf(p.tags, "since") != null or tagOf(p.tags, "drift") != null) return .derived;
    return .other;
}

/// The names of a unit's or a cycle's places, its `names`; none where its places are numbers.
pub fn names(p: *const ast.Subsection) []const []const u8 {
    return if (tagOf(p.tags, "names")) |t| t.values else &.{};
}

/// The calendar's `n`th part of a kind, `.unit` or `.cycle`, as tide numbers units and cycles.
pub fn nth(s: *const ast.Section, of: What, n: usize) ?*const ast.Subsection {
    var i: usize = 0;
    for (s.subsections) |*p| if (what(p) == of) {
        if (i == n) return p;
        i += 1;
    };
    return null;
}

/// The number of the unit or cycle called `name`, as tide numbers them.
pub fn numbered(s: *const ast.Section, of: What, name: []const u8) ?u8 {
    var i: u8 = 0;
    for (s.subsections) |*p| if (what(p) == of) {
        if (std.mem.eql(u8, p.name.text, name)) return i;
        if (i == std.math.maxInt(u8)) return null;
        i += 1;
    };
    return null;
}

/// A time a calendar's words name.
pub const Instant = struct {
    /// The unit counted, and its count, the instant is at or after: `day 34`.
    count: ?struct { unit: u8, n: u64 } = null,
    /// The places that must hold, as `Calendar.next` takes them.
    wants: [tide.calendar.max_units + tide.calendar.max_cycles]Want = undefined,
    len: usize = 0,

    pub fn places(i: *const Instant) []const Want {
        return i.wants[0..i.len];
    }
};

/// What an instant's words are against a calendar: the instant, or what does not fit, for a writer.
pub const Read = union(enum) { instant: Instant, problem: []const u8 };

/// An instant's words, each tag value split at its spaces, read against the calendar section `s`.
pub fn instant(a: std.mem.Allocator, s: *const ast.Section, values: []const []const u8) error{OutOfMemory}!Read {
    var words: std.ArrayList([]const u8) = .empty;
    for (values) |v| {
        var it = std.mem.tokenizeScalar(u8, v, ' ');
        while (it.next()) |w| try words.append(a, w);
    }
    var out: Instant = .{};
    var i: usize = 0;
    while (i < words.items.len) : (i += 1) {
        const w = words.items[i];
        const next: ?[]const u8 = if (i + 1 < words.items.len) words.items[i + 1] else null;
        if (counted(s, w)) |unit| {
            const n = number(next orelse "") orelse return problem(a, "`{s}` takes its count: `{s} 34`", .{ w, w });
            if (out.count != null) return problem(a, "a time has one count, and `{s}` is a second", .{w});
            out.count = .{ .unit = unit, .n = n };
            i += 1;
            continue;
        }
        const want = if (placed(s, w)) |at| blk: {
            i += 1;
            break :blk try valueOf(a, s, at, w, next orelse "");
        } else try named(a, s, w);
        switch (want) {
            .problem => |p| return .{ .problem = p },
            .want => |found| {
                const fact = only(tagOf(partOf(s, found.what).tags, "place").?);
                for (out.places()) |had| if (std.meta.eql(had.what, found.what)) return problem(a, "`{s}` is given twice", .{fact});
                out.wants[out.len] = found;
                out.len += 1;
            },
        }
    }
    return .{ .instant = out };
}

fn problem(a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!Read {
    return .{ .problem = try a.print(fmt, args) };
}

/// A place of the calendar: a unit's in the next, or a cycle's.
const Place = @FieldType(Want, "what");

// The unit whose count fact is `name`.
fn counted(s: *const ast.Section, name: []const u8) ?u8 {
    for (0..tide.calendar.max_units) |u| {
        const p = nth(s, .unit, u) orelse return null;
        if (tagOf(p.tags, "count")) |t| if (std.mem.eql(u8, only(t), name)) return @intCast(u); // safe: below max_units
    }
    return null;
}

// The place whose fact is `name`.
fn placed(s: *const ast.Section, name: []const u8) ?Place {
    for (0..tide.calendar.max_units) |u| {
        const p = nth(s, .unit, u) orelse break;
        if (tagOf(p.tags, "place")) |t| if (std.mem.eql(u8, only(t), name)) return .{ .place = @intCast(u) }; // safe: below max_units
    }
    for (0..tide.calendar.max_cycles) |j| {
        const p = nth(s, .cycle, j) orelse break;
        if (tagOf(p.tags, "place")) |t| if (std.mem.eql(u8, only(t), name)) return .{ .cycle = @intCast(j) }; // safe: below max_cycles
    }
    return null;
}

/// The part a place is.
pub fn partOf(s: *const ast.Section, at: Place) *const ast.Subsection {
    return switch (at) {
        .place => |u| nth(s, .unit, u).?,
        .cycle => |j| nth(s, .cycle, j).?,
    };
}

const Found = union(enum) { want: Want, problem: []const u8 };

// `weekday sunday`, or `date 5` where the places are numbers.
fn valueOf(a: std.mem.Allocator, s: *const ast.Section, at: Place, fact: []const u8, v: []const u8) error{OutOfMemory}!Found {
    const list = names(partOf(s, at));
    if (list.len == 0) {
        const n = number(v) orelse return .{ .problem = try a.print("`{s}` takes a number: `{s}` is not one", .{ fact, v }) };
        return .{ .want = .{ .what = at, .value = n } };
    }
    for (list, 0..) |n, k| if (std.mem.eql(u8, n, v)) return .{ .want = .{ .what = at, .value = k } };
    return .{ .problem = try a.print("`{s}` is one of {s}: `{s}` is not one", .{ fact, try std.mem.join(a, ", ", list), v }) };
}

// A place's name alone, `sunday`, where it is the name of one place of the calendar.
fn named(a: std.mem.Allocator, s: *const ast.Section, w: []const u8) error{OutOfMemory}!Found {
    var found: ?Want = null;
    var first: []const u8 = "";
    for (s.subsections) |*p| {
        const at = placeOfPart(s, p) orelse continue;
        for (names(p), 0..) |n, k| if (std.mem.eql(u8, n, w)) {
            const fact = only(tagOf(p.tags, "place").?);
            if (found != null) return .{ .problem = try a.print("`{s}` is a place of `{s}` and of `{s}`: say which, `{s} {s}`", .{ w, first, fact, first, w }) };
            found = .{ .what = at, .value = k };
            first = fact;
        };
    }
    if (found) |f| return .{ .want = f };
    return .{ .problem = try a.print("`{s}` is not a place or a count of `{s}`", .{ w, s.name.text }) };
}

// The place a part holds, where it is a unit or a cycle with a place fact.
fn placeOfPart(s: *const ast.Section, p: *const ast.Subsection) ?Place {
    if (tagOf(p.tags, "place") == null) return null;
    return switch (what(p)) {
        .unit => .{ .place = numbered(s, .unit, p.name.text) orelse return null },
        .cycle => .{ .cycle = numbered(s, .cycle, p.name.text) orelse return null },
        else => null,
    };
}

/// The calendar a schedule's tags mean, by its section's number in `sections`: the one `calendar` names, else the
/// one whose places or counts its `at` names, else the only one. Null where that is none or more than one, which
/// `which` says.
pub fn calendarFor(sections: []const sym.Section, tags: []const ast.Tag) ?usize {
    return switch (which(sections, tags)) {
        .one => |i| i,
        else => null,
    };
}

pub const Which = union(enum) { one: usize, named_none, none, several, unsaid };

/// Why a schedule has the calendar it has, or has none.
pub fn which(sections: []const sym.Section, tags: []const ast.Tag) Which {
    if (tagOf(tags, "calendar")) |t| {
        for (sections, 0..) |s, i| if (isCalendar(s) and std.mem.eql(u8, s.name, only(t))) return .{ .one = i };
        return .named_none;
    }
    var found: ?usize = null;
    var count: usize = 0;
    for (sections, 0..) |s, i| if (isCalendar(s)) {
        count += 1;
        const at = tagOf(tags, "at") orelse continue;
        if (!mentions(s.node, at.values)) continue;
        if (found != null) return .several;
        found = i;
    };
    if (found) |f| return .{ .one = f };
    if (count == 0) return .none;
    if (count > 1) return .unsaid;
    for (sections, 0..) |s, i| if (isCalendar(s)) return .{ .one = i };
    unreachable; // unreachable: one calendar was counted
}

// Whether the words name any place or count of the calendar.
fn mentions(s: *const ast.Section, values: []const []const u8) bool {
    for (values) |v| {
        var it = std.mem.tokenizeScalar(u8, v, ' ');
        while (it.next()) |w| {
            if (counted(s, w) != null or placed(s, w) != null) return true;
            for (s.subsections) |*p| if (placeOfPart(s, p) != null) for (names(p)) |n| if (std.mem.eql(u8, n, w)) return true;
        }
    }
    return false;
}

test "an instant's words: counts, places by fact and by name" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const unit = [_]ast.Tag{
        .{ .key = .{ .text = "size", .span = .none }, .values = &.{"1"} },
        .{ .key = .{ .text = "place", .span = .none }, .values = &.{"slot"} },
        .{ .key = .{ .text = "names", .span = .none }, .values = &.{ "morning", "evening" } },
    };
    const day = [_]ast.Tag{ .{ .key = .{ .text = "size", .span = .none }, .values = &.{"2"} }, .{ .key = .{ .text = "count", .span = .none }, .values = &.{"day"} } };
    const parts = [_]ast.Subsection{
        .{ .name = .{ .text = "slot", .span = .none }, .when = null, .tags = &unit, .body = &.{} },
        .{ .name = .{ .text = "day", .span = .none }, .when = null, .tags = &day, .body = &.{} },
    };
    const s: ast.Section = .{ .name = .{ .text = "school", .span = .none }, .kind = .scene, .tags = &.{}, .body = &.{}, .subsections = &parts };
    const read = try instant(a, &s, &.{"day 3 evening"});
    try std.testing.expectEqual(@as(u64, 3), read.instant.count.?.n);
    try std.testing.expectEqual(@as(u64, 1), read.instant.places()[0].value);
    try std.testing.expectEqual(@as(u64, 0), (try instant(a, &s, &.{ "slot morning", "day 1" })).instant.places()[0].value);
    try std.testing.expectEqualStrings("`slot` is one of morning, evening: `noon` is not one", (try instant(a, &s, &.{"slot noon"})).problem);
    try std.testing.expectEqualStrings("`dawn` is not a place or a count of `school`", (try instant(a, &s, &.{"dawn"})).problem);
    try std.testing.expectEqualStrings("`day` takes its count: `day 34`", (try instant(a, &s, &.{"day"})).problem);
    try std.testing.expectEqualStrings("`slot` is given twice", (try instant(a, &s, &.{"evening slot evening"})).problem);
}
