//! tide's time as riverrun's tools run it when a story is played without
//! its game (`riverrun play`): the story's calendar loaded over the played
//! story's facts, its facts written from the start, and a clock the player
//! moves (`:wait`) moved by tide, so the calendar's facts and the time facts
//! follow it and every schedule that comes due on the way is told, in time
//! order, with the section it carries for the play to tell then.

const std = @import("std");
const river = @import("riverrun-compiler");
const runtime = @import("riverrun");
const tide = @import("tide");

const facts = runtime.facts;
const story = runtime.story;

/// What `tide.package` runs as a story is played.
pub const running: river.Running = .{ .name = "tide", .start = start, .stop = stop, .advance = advance };

const State = struct { tide: tide.Tide, story: *const story.Story };

fn start(gpa: std.mem.Allocator, game: river.Running.Game, told: *river.Running.Told) error{ OutOfMemory, Stopped }!?*anyopaque {
    if (game.story.block(tide.block.name) == null) return null;
    const st = try gpa.create(State);
    errdefer gpa.destroy(st);
    st.* = .{ .story = game.story, .tide = tide.fromStory(gpa, game.story, game.store, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return told.stop("tide could not load the story's time ({t}): this is tide's fault, not the story's", .{e}),
    } };
    errdefer st.tide.deinit();
    st.tide.sync() catch |e| return told.stop("tide could not write the calendar's facts ({t})", .{e});
    return st;
}

fn stop(gpa: std.mem.Allocator, state: *anyopaque) void {
    const st: *State = @ptrCast(@alignCast(state));
    st.tide.deinit();
    gpa.destroy(st);
}

// A clock tide keeps, moved on as far as the player says, and what came due on the way told, each with its section.
fn advance(state: *anyopaque, clock: facts.FactId, by: u64, told: *river.Running.Told) error{ OutOfMemory, Stopped }!bool {
    const st: *State = @ptrCast(@alignCast(state));
    const c = st.tide.clockOf(clock) orelse return false;
    const name = st.story.fact(clock).name;
    var due: [64]tide.Due = undefined;
    var left = by;
    while (true) {
        const moved = st.tide.advance(c, left, &due) catch |e| return told.stop("`{s}` could not move on {d} ({t})", .{ name, left, e });
        for (moved.due) |d| {
            const section: story.SectionId = .fromRaw(std.math.cast(u32, d.key) orelse return told.stop("a schedule came due for no section of the story", .{}));
            const when = if (d.count > 1)
                try told.arena.print("at {s} {d}, for {d} times", .{ name, d.at, d.count })
            else
                try told.arena.print("at {s} {d}", .{ name, d.at });
            try told.say(.{ .what = "due", .name = st.story.section(section).name, .words = &.{when}, .section = section });
        }
        if (moved.left == 0) return true;
        left = moved.left;
    }
}
