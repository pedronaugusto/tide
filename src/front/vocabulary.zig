//! What tide adds to a story's language: the `calendar` kind of section,
//! the tags that put a section on the calendar, and its check and pass,
//! registered as one package. No grammar: a calendar is a section whose
//! parts are its units, its cycles and the time facts it keeps, and a
//! schedule is tags on any section, part or pool candidate.
//!
//!     == school (calendar)
//!       [clock turn] [scope time]
//!     = slot
//!       [size 1] [place slot] [names morning, noon, afternoon, evening]
//!     = day
//!       [size 4] [count day]
//!     = week
//!       [cycle day] [place weekday] [names monday, tuesday, wednesday, thursday, friday, saturday, sunday]
//!     = days_left
//!       [until day 34] [per day]
//!
//!     == ramen
//!       [every week] [at sunday evening] [times 5]
//!     { weekday = sunday and slot = evening } RYUJI: yo. ramen?
//!     -> end
//!
//! The calendar declares the facts it keeps (`slot`, `day`, `weekday`,
//! `days_left`), which the story reads and never declares. A time is
//! written in them (`[at sunday evening]`, `[until day 34]`), and tide's judges
//! hold it to the calendar, so a typo fails with its file and line.

const riverrun = @import("riverrun-compiler");
const declare = @import("declare.zig");
const judge = @import("judge.zig");
const pass = @import("pass.zig");

const Schema = riverrun.check.Schema;
const Key = Schema.Key;

const section: Schema.Places = .{ .section = true };
const part: Schema.Places = .{ .part = true };
const anywhere: Schema.Places = .{ .section = true, .part = true };

const calendar_schema: Schema = .{
    .keys = &.{
        // the calendar: the `(clock)` fact it reads, where the clock's zero falls in it, and the scope its facts keep
        .{ .name = "clock", .on = section, .value = .{ .judge = judge.clock } },
        .{ .name = "start", .on = section, .value = .number },
        .{ .name = "scope", .on = section, .value = .word },
        // a unit: its size in the unit before (ticks for the first), several for sizes that repeat in turn
        .{ .name = "size", .on = part, .value = .number, .count = .many },
        // the fact that keeps a unit's place in the next, or a cycle's, and the names of its places
        .{ .name = "place", .on = part, .value = .word },
        .{ .name = "names", .on = part, .value = .word, .count = .many },
        // the fact that counts a unit
        .{ .name = "count", .on = part, .value = .word },
        // a cycle round a unit: a week of days
        .{ .name = "cycle", .on = part, .value = .{ .judge = judge.cycle } },
        .{ .name = "length", .on = part, .value = .number },
        .{ .name = "offset", .on = part, .value = .number },
        // a time fact the calendar keeps, named by the part: until or since an instant, or one clock's drift
        .{ .name = "until", .on = part, .value = .{ .judge = judge.instant }, .count = .many },
        .{ .name = "since", .on = part, .value = .{ .judge = judge.instant }, .count = .many },
        .{ .name = "drift", .on = part, .value = .{ .judge = judge.clock } },
        .{ .name = "per", .on = part, .value = .{ .judge = judge.per } },
    },
};

/// The kind of section tide registers, which declares the facts its calendar keeps.
pub const kind: riverrun.check.Kind = .{ .name = "calendar", .schema = &calendar_schema, .declare = declare.declare };

/// A schedule's tags, on any section or part: one time (`at`) or a recurrence (`every`, from `at` where it is
/// given), how many times, what a jump does with the times it passes, and the calendar where a story has several.
/// A section scheduled so comes due into a running flow, as an interruption: `<-` goes back to where the flow was.
pub const keys = [_]Key{
    .{ .name = "at", .on = anywhere, .value = .{ .judge = judge.at }, .count = .many, .interrupts = true },
    .{ .name = "every", .on = anywhere, .value = .{ .judge = judge.every }, .interrupts = true },
    .{ .name = "interval", .on = anywhere, .value = .number },
    .{ .name = "times", .on = anywhere, .value = .number },
    .{ .name = "policy", .on = anywhere, .value = .{ .words = &.{ "each", "once" } } },
    .{ .name = "calendar", .on = anywhere, .value = .{ .judge = judge.calendar } },
};

/// What a game's vocabulary registers: `pub const packages = &.{tide.package}`.
pub const package: riverrun.Package = .{
    .kinds = &.{kind},
    .keys = &keys,
    .check = .{ .run = pass.check },
    .compile = .{ .name = "tide", .run = pass.compile },
    .running = @import("running.zig").running,
};
