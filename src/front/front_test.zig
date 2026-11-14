//! A calendar written in `.river`, checked and compiled with tide registered
//! as a game's vocabulary registers it, loaded and advanced: what a game's
//! build and its run do with tide.

const std = @import("std");
const riverrun = @import("riverrun-compiler");
const runtime = @import("riverrun");
const tide = @import("tide");
const vocabulary = @import("vocabulary.zig");

const gpa = std.testing.allocator;
const check = riverrun.check;

/// A vocabulary with tide registered and nothing of a game's own.
const Vocabulary = struct {
    pub const options: check.Options = .{};
    pub const packages: []const riverrun.Package = &.{vocabulary.package};
};
const joined = riverrun.join(Vocabulary);

/// A school year as Persona keeps one: four slots a day, a seven-day week, a deadline, and a friend who asks on
/// Sunday evenings.
pub const school = @embedFile("testdata/school.river");

pub const Built = struct {
    arena: std.heap.ArenaAllocator,
    diags: riverrun.syntax.Diagnostics,
    /// The story's one file, as read.
    tree: ?*const riverrun.syntax.ast.File = null,
    checked: ?check.Checked = null,
    compiled: ?riverrun.compile.Compiled = null,

    pub fn deinit(b: *Built) void {
        if (b.compiled) |*c| c.deinit(gpa);
        if (b.checked) |*c| c.deinit();
        b.diags.deinit(gpa);
        b.arena.deinit();
    }

    /// Where a diagnostic is, as a line and a column.
    pub fn at(b: *const Built, d: riverrun.syntax.source.Diagnostic) riverrun.syntax.Place {
        return b.tree.?.place(d.span);
    }

    /// The one error there is, which must be this one.
    fn only(b: *const Built, line: u32, col: u32, message: []const u8) !void {
        if (b.diags.errors() != 1) for (b.diags.list.items) |d| std.debug.print("{d}:{d}: {s}\n", .{ b.at(d).line, b.at(d).col, d.message });
        try std.testing.expectEqual(@as(usize, 1), b.diags.errors());
        for (b.diags.list.items) |d| if (d.severity == .err) {
            try std.testing.expectEqualStrings(message, d.message);
            try std.testing.expectEqual(line, b.at(d).line);
            try std.testing.expectEqual(col, b.at(d).col);
        };
        try std.testing.expect(b.compiled == null);
    }
};

/// Reads, checks (riverrun's checker, tide's within it) and, when nothing is wrong, compiles `text`.
pub fn build(text: []const u8) !Built {
    var b: Built = .{ .arena = .init(gpa), .diags = .{} };
    errdefer b.deinit();
    const tree = try b.arena.allocator().create(riverrun.syntax.ast.File);
    tree.* = try riverrun.syntax.parse(b.arena.allocator(), gpa, &b.diags, 0, "school.river", text);
    b.tree = tree;
    b.checked = try check.run(gpa, &b.diags, tree[0..1], joined.options);
    if (b.diags.errors() == 0) b.compiled = try riverrun.compile.run(gpa, &b.diags, &b.checked.?, .{ .passes = joined.passes });
    return b;
}

fn replaced(text: []const u8, from: []const u8, to: []const u8) ![]u8 {
    try std.testing.expect(std.mem.find(u8, text, from) != null);
    return std.mem.replaceOwned(u8, gpa, text, from, to);
}

test "a calendar in the story is compiled, loaded and kept: Sunday evening comes, and Ryuji asks" {
    var b = try build(school);
    defer b.deinit();
    for (b.diags.list.items) |d| if (d.severity == .err) std.debug.print("{d}:{d}: {s}\n", .{ b.at(d).line, b.at(d).col, d.message });
    try std.testing.expectEqual(@as(usize, 0), b.diags.errors());
    const s: runtime.story.Story = try .init(b.compiled.?.graph, .{});
    const words: runtime.story.Strings = try .init(b.compiled.?.words, .{});
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var memory: runtime.facts.Memory = try .init(gpa, try s.schema(arena.allocator()));
    defer memory.deinit();
    var t = try tide.fromStory(gpa, &s, memory.store(), .{});
    defer t.deinit();
    try t.sync();
    const turn = t.clockNamed("turn").?;
    // the calendar's own facts, in the scope it names
    const weekday = s.factNamed("weekday").?;
    const slot = s.factNamed("slot").?;
    const days_left = s.factNamed("days_left").?;
    try std.testing.expectEqualStrings("time", s.scope(s.fact(weekday).scope));
    try std.testing.expectEqual(@as(u16, 0), memory.get(weekday).one_of);
    try std.testing.expectEqual(@as(i64, 34), memory.get(days_left).int);

    // six days and three slots: Sunday evening, the schedule's first occurrence
    var due: [8]tide.Due = undefined;
    const a = try t.advance(turn, 26, &due);
    try std.testing.expectEqual(@as(usize, 0), a.due.len);
    const b2 = try t.advance(turn, 1, &due);
    try std.testing.expectEqual(@as(usize, 1), b2.due.len);
    try std.testing.expectEqual(@as(u64, s.sectionNamed("ramen").?.raw()), b2.due[0].key);
    try std.testing.expectEqual(@as(u16, 6), memory.get(weekday).one_of);
    try std.testing.expectEqual(@as(u16, 3), memory.get(slot).one_of);
    // the deadline counts the days begun before it: from day 6 to day 34
    try std.testing.expectEqual(@as(i64, 28), memory.get(days_left).int);

    // what the schedule's section says, now that its condition holds
    var session: runtime.run.Session = try .init(gpa, &s, &words, memory.store(), &runtime.run.Host.none, .{});
    defer session.deinit();
    const flow: runtime.run.FlowId = .fromRaw(0);
    try session.start(flow, s.sectionNamed("ramen").?);
    try std.testing.expectEqualStrings("yo. ramen?", (try session.next(flow)).line.text);

    // a week on, it comes due again; five times in all
    var total: usize = 1;
    for (0..6) |_| total += (try t.advance(turn, 28, &due)).due.len;
    try std.testing.expectEqual(@as(usize, 5), total);
}

test "a time misnamed is refused by tide's judge, where its value is written" {
    const cases = .{
        .{ "at sunday evening", "at sundy evening", 14, 59, "`sundy` is not a place or a count of `school`" },
        .{ "at sunday evening", "at weekday evening", 14, 59, "`weekday` is one of monday, tuesday, wednesday, thursday, friday, saturday, sunday: `evening` is not one" },
        .{ "until day 34", "until day", 12, 17, "`day` takes its count: `day 34`" },
        .{ "# every week ·", "# every fortnight ·", 14, 51, "`fortnight` is not a unit or a cycle of this calendar" },
        .{ "# cycle day ·", "# cycle month ·", 11, 23, "`month` is not a unit of this calendar" },
        .{ "# clock turn", "# clock day", 8, 51, "`day` is not a `(clock)` fact" },
    };
    inline for (cases) |c| {
        const text = try replaced(school, c[0], c[1]);
        defer gpa.free(text);
        var b = try build(text);
        defer b.deinit();
        try b.only(c[2], c[3], c[4]);
    }
}

test "what only the whole calendar shows is said by tide's check, at its place" {
    const cases = .{
        .{ "= day         # size 4", "= day         # size 5", 8, 4, "the calendar does not hold together: a unit's names are not one for each of its places in the next unit, or a cycle's for each of its length" },
        .{ "= week        # cycle day · place", "= week        # cycle day · offset 9 · place", 8, 4, "the calendar does not hold together: a cycle is of length zero, or starts past its end" },
        .{ "= days_left   # until day 34", "= days_left   # per day", 12, 3, "a calendar's part is a unit (`size`), a cycle (`cycle`) or a time fact it keeps (`until`, `since`, `drift`)" },
    };
    inline for (cases) |c| {
        const text = try replaced(school, c[0], c[1]);
        defer gpa.free(text);
        var b = try build(text);
        defer b.deinit();
        try b.only(c[2], c[3], c[4]);
    }
}

test "a fact the calendar keeps is never the story's too" {
    const text = try replaced(school, "  turn:  int   (clock)", "  turn:  int   (clock)\n  weekday: int   (game)");
    defer gpa.free(text);
    var b = try build(text);
    defer b.deinit();
    try std.testing.expectEqualStrings("`weekday` is declared twice: first at school.river:7:3, then by the calendar `school`", b.diags.list.items[0].message);
    try std.testing.expectEqual(@as(u32, 12), b.at(b.diags.list.items[0]).line);
}

test "a schedule needs a calendar to mean" {
    var none = try build("== bus   # at day 3\n-> end\n");
    defer none.deinit();
    try none.only(1, 4, "a schedule needs a calendar: the story declares none");
}

test "a place without names is a number, kept in an int" {
    var b = try build(
        \\facts:
        \\  minutes: int   (clock)
        \\== clock (calendar)   # clock minutes
        \\= hour   # size 60 · place hour
        \\= day    # size 24 · count day
        \\== late
        \\{ hour >= 22 } It is late.
        \\-> end
    );
    defer b.deinit();
    try std.testing.expectEqual(@as(usize, 0), b.diags.errors());
    const s: runtime.story.Story = try .init(b.compiled.?.graph, .{});
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var memory: runtime.facts.Memory = try .init(gpa, try s.schema(arena.allocator()));
    defer memory.deinit();
    var t = try tide.fromStory(gpa, &s, memory.store(), .{});
    defer t.deinit();
    var due: [1]tide.Due = undefined;
    _ = try t.advance(t.clockNamed("minutes").?, 23 * 60, &due);
    try std.testing.expectEqual(@as(i64, 23), memory.get(s.factNamed("hour").?).int);
}

test "a story without its block, or with a damaged one, is refused before anything is kept" {
    var b = try build(school);
    defer b.deinit();
    const graph = b.compiled.?.graph;
    const s: runtime.story.Story = try .init(graph, .{});
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var memory: runtime.facts.Memory = try .init(gpa, try s.schema(arena.allocator()));
    defer memory.deinit();
    // the block read alone: cut short anywhere, it is refused
    const blk = s.block(tide.block.name).?;
    for (0..blk.bytes.len) |n| try std.testing.expectError(error.Malformed, tide.block.read(arena.allocator(), blk.bytes[0..n]));
    // a story that declares no time has no block
    var other = try build("== a\n-> end\n");
    defer other.deinit();
    const without: runtime.story.Story = try .init(other.compiled.?.graph, .{});
    try std.testing.expectError(error.NoTime, tide.fromStory(gpa, &without, null, .{}));
}
