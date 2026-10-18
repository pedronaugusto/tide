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
}
