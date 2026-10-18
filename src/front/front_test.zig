//! A calendar written in `.river`, compiled with tide's pass, loaded and
//! advanced: what a game's build and its run do with tide.

const std = @import("std");
const riverrun = @import("riverrun-compiler");
const runtime = @import("riverrun");
const tide = @import("tide");
const vocabulary = @import("vocabulary.zig");
const pass = @import("pass.zig");

const gpa = std.testing.allocator;
const check = riverrun.check;

const keys = vocabulary.schedule(&.{ "slot", "weekday" }, &.{"day"});
const schema: check.Schema = .{ .keys = &keys };
pub const options: check.Options = .{ .schema = &schema, .kinds = &.{vocabulary.kind} };

/// A school year as Persona keeps one: four slots a day, a seven-day week, a deadline, and a friend who asks on
/// Sunday evenings.
pub const school =
    \\cast:
    \\  ryuji  "Ryuji"
    \\facts (time):
    \\  turn:      int   (clock)
    \\  day:       int   (game)
    \\  slot:      one of morning, noon, afternoon, evening   (game)
    \\  weekday:   one of monday, tuesday, wednesday, thursday, friday, saturday, sunday   (game)
    \\  days_left: int   (game)
    \\
    \\== school (calendar)                      # clock turn
    \\= slot        # size 1 · place slot
    \\= day         # size 4 · count day
    \\= week        # cycle day · length 7 · place weekday
    \\= days_left   # until · day 34 · per day
    \\
    \\== ramen                                  # every week · weekday sunday · slot evening · times 5
    \\{ weekday = sunday and slot = evening } RYUJI: yo. ramen?
    \\-> end
;

pub const Built = struct {
    arena: std.heap.ArenaAllocator,
    diags: riverrun.syntax.Diagnostics,
    checked: ?check.Checked = null,
    compiled: ?riverrun.compile.Compiled = null,

    pub fn deinit(b: *Built) void {
        if (b.compiled) |*c| c.deinit(gpa);
        if (b.checked) |*c| c.deinit();
        b.diags.deinit(gpa);
        b.arena.deinit();
    }
};

/// Reads, checks (riverrun's checker, then tide's) and, when nothing is wrong, compiles `text`.
pub fn build(text: []const u8, with: check.Options) !Built {
    var b: Built = .{ .arena = .init(gpa), .diags = .{} };
    errdefer b.deinit();
    const tree = try b.arena.allocator().create(riverrun.syntax.ast.File);
    tree.* = try riverrun.syntax.parse(b.arena.allocator(), gpa, &b.diags, 0, "school.river", text);
    b.checked = try check.run(gpa, &b.diags, tree[0..1], with);
    try pass.check(gpa, &b.diags, &b.checked.?);
    if (b.diags.errors() == 0) b.compiled = try riverrun.compile.run(gpa, &b.diags, &b.checked.?, .{ .passes = &.{pass.pass} });
    return b;
}

test "a calendar in the story is compiled, loaded and kept: Sunday evening comes, and Ryuji asks" {
    var b = try build(school, options);
    defer b.deinit();
    for (b.diags.list.items) |d| std.debug.print("{d}:{d}: {s}\n", .{ d.span.line, d.span.col, d.message });
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
    const weekday = s.factNamed("weekday").?;
    const slot = s.factNamed("slot").?;
    const days_left = s.factNamed("days_left").?;
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

test "a day misnamed in a schedule is refused where it is written" {
    const typo = std.mem.replaceOwned(u8, gpa, school, "weekday sunday", "weekday sundy") catch unreachable;
    defer gpa.free(typo);
    var b = try build(typo, options);
    defer b.deinit();
    try std.testing.expectEqual(@as(usize, 1), b.diags.errors());
    const d = b.diags.list.items[0];
    try std.testing.expectEqual(@as(u32, 16), d.span.line);
    try std.testing.expectEqual(@as(u32, 59), d.span.col);
    try std.testing.expect(std.mem.find(u8, d.message, "sundy") != null);
    try std.testing.expect(b.compiled == null);
}

test "what does not hold together in a calendar is said at its place" {
    const cases = .{
        .{ "# clock turn", "# clock day", 10, "`day` is not a `(clock)` fact" },
        .{ "= day         # size 4 · count day", "= day         # size 5 · count day", 10, "the calendar does not hold together: a place fact's values do not number the places of the next unit" },
        .{ "# cycle day ·", "# cycle month ·", 13, "`month` is not a unit of this calendar" },
        .{ "# every week ·", "# every fortnight ·", 16, "`fortnight` is not a unit or a cycle of this calendar" },
    };
    inline for (cases) |c| {
        const text = try std.mem.replaceOwned(u8, gpa, school, c[0], c[1]);
        defer gpa.free(text);
        var b = try build(text, options);
        defer b.deinit();
        if (b.diags.errors() != 1) for (b.diags.list.items) |d| std.debug.print("{s}: {d}:{d}: {s}\n", .{ c[1], d.span.line, d.span.col, d.message });
        try std.testing.expectEqual(@as(usize, 1), b.diags.errors());
        try std.testing.expectEqual(@as(u32, c[2]), b.diags.list.items[0].span.line);
        try std.testing.expectEqualStrings(c[3], b.diags.list.items[0].message);
    }
}

test "a story without its block, or with a damaged one, is refused before anything is kept" {
    var b = try build(school, options);
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
    var other = try build("== a\n-> end\n", options);
    defer other.deinit();
    const without: runtime.story.Story = try .init(other.compiled.?.graph, .{});
    try std.testing.expectError(error.NoTime, tide.fromStory(gpa, &without, null, .{}));
}
