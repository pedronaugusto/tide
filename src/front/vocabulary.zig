//! What tide adds to a story's language: the `calendar` kind of section, and
//! the tags that put a section on the calendar. No grammar: a calendar is a
//! section whose parts are its units, its cycles and the time facts it keeps,
//! and a schedule is tags on any section, part or pool candidate.
//!
//!     == school (calendar)                    # clock turn
//!     = slot       # size 1 · place slot
//!     = day        # size 4 · count day
//!     = week       # cycle day · length 7 · place weekday
//!     = days_left  # until · day 34 · per day
//!
//!     == ramen                                # every week · weekday sunday · slot evening · times 5
//!
//! The tags that name a time (`weekday sunday`, `slot evening`, `day 34`)
//! are keyed by the calendar's own facts, so the checker holds `sunday` to
//! the values of `weekday` and a typo fails with its file and line. A game
//! names those facts when it builds its vocabulary: `schedule(places, counts)`.

const riverrun = @import("riverrun-compiler");

const Schema = riverrun.check.Schema;
const Key = Schema.Key;

const section: Schema.Places = .{ .section = true };
const part: Schema.Places = .{ .part = true };
const anywhere: Schema.Places = .{ .section = true, .part = true };

const calendar_schema: Schema = .{
    .keys = &.{
        // the calendar: the `(clock)` fact it reads, and where the clock's zero falls in it
        .{ .name = "clock", .on = section, .value = .word },
        .{ .name = "start", .on = section, .value = .number },
        // a unit: its size in the unit before (ticks for the first), several for sizes that repeat in turn
        .{ .name = "size", .on = part, .value = .number, .count = .many },
        .{ .name = "place", .on = part, .value = .word },
        .{ .name = "count", .on = part, .value = .word },
        // a cycle round a unit: a week of days
        .{ .name = "cycle", .on = part, .value = .word },
        .{ .name = "length", .on = part, .value = .number },
        .{ .name = "offset", .on = part, .value = .number },
        // a time fact the calendar keeps, named by the part: until or since an instant, or one clock's drift
        .{ .name = "until", .on = part },
        .{ .name = "since", .on = part },
        .{ .name = "drift", .on = part, .value = .word },
        .{ .name = "per", .on = part, .value = .word },
    },
};

/// The kind of section tide registers.
pub const kind: riverrun.check.Kind = .{ .name = "calendar", .schema = &calendar_schema };

/// The keys of a schedule and of an instant, for the game's own schema: `at` or `every`, `times`, `policy`,
/// `interval`, `calendar` where a story has several, and one key for each calendar fact that names a time,
/// `places` (its `one of` facts: `weekday`, `slot`) and `counts` (its int facts: `day`).
pub fn schedule(comptime places: []const []const u8, comptime counts: []const []const u8) [6 + places.len + counts.len]Key {
    const fixed = [6]Key{
        .{ .name = "at", .on = anywhere },
        .{ .name = "every", .on = anywhere, .value = .word },
        .{ .name = "interval", .on = anywhere, .value = .number },
        .{ .name = "times", .on = anywhere, .value = .number },
        .{ .name = "policy", .on = anywhere, .value = .{ .words = &.{ "each", "once" } } },
        .{ .name = "calendar", .on = anywhere, .value = .section },
    };
    var keys: [6 + places.len + counts.len]Key = undefined;
    @memcpy(keys[0..6], &fixed);
    for (places, 0..) |p, i| keys[6 + i] = .{ .name = p, .on = anywhere, .value = .{ .values_of = p } };
    for (counts, 0..) |c, i| keys[6 + places.len + i] = .{ .name = c, .on = anywhere, .value = .number };
    return keys;
}
