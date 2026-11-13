//! tide: a game's time. Clocks the host advances, calendars that read them as
//! the game's own time, schedules that come due, and facts kept current
//! through a riverrun store, so dialogue, quests and the world read one time
//! without knowing tide.

pub const Tide = @import("tide/Tide.zig");
pub const Rate = @import("tide/rate.zig").Rate;
pub const calendar = @import("tide/calendar.zig");
pub const Calendar = calendar.Calendar;
pub const schedule = @import("tide/schedule.zig");
pub const Recurrence = schedule.Recurrence;
pub const Policy = schedule.Policy;
pub const snapshot = @import("tide/snapshot.zig");
/// tide's block in a compiled story, which its compile pass writes and `fromStory` reads.
pub const block = @import("tide/block.zig");
const load = @import("tide/load.zig");
/// The time a compiled story declares (its calendars, clocks, derived facts and schedules, from tide's block),
/// its facts written through a store. What comes due from a schedule the story declared carries the section's
/// id as its key.
pub const fromStory = load.fromStory;
pub const LoadOptions = load.Options;
pub const LoadError = load.Error;

pub const ClockId = Tide.ClockId;
pub const CalendarId = Tide.CalendarId;
pub const Options = Tide.Options;
pub const Due = Tide.Due;
pub const Token = Tide.Token;

test {
    _ = Tide;
    _ = @import("tide/rate.zig");
    _ = calendar;
    _ = @import("tide/queue.zig");
    _ = schedule;
    _ = snapshot;
    _ = block;
    _ = load;
    _ = @import("tide/block_test.zig");
}
