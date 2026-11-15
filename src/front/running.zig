//! tide's time as riverrun's tools run it when a story is played without
//! its game (`riverrun play`): the story's calendar loaded over the played
//! story's facts, its facts written from the start, and a clock the player
//! moves (`:wait`) moved by tide, so the calendar's facts and the time facts
//! follow it and every schedule that comes due on the way is told, in time
//! order, with the section it carries for the play to tell then.
//!
//! Moving a clock is the play's own `:wait`, since a `(clock)` fact is
//! riverrun's; tide moves it where it keeps it. The game's one other call
//! into tide that changes what the story tells is offered as the play's
//! command `:cancel SECTION`: the game's `cancelKey`, a scene the story
//! schedules taken off the calendar, so it never comes due again.

const std = @import("std");
const river = @import("riverrun-compiler");
const runtime = @import("riverrun");
const tide = @import("tide");

const facts = runtime.facts;
const story = runtime.story;

/// What `tide.package` runs as a story is played.
pub const running: river.Running = .{ .name = "tide", .start = start, .stop = stop, .advance = advance, .commands = &.{
    .{ .name = "cancel", .object = "scene", .help = "the game takes a scene the story schedules off the calendar: it comes due no more", .forms = scheduled, .run = cancel },
} };

const State = struct { tide: tide.Tide, story: *const story.Story };

// The sections the story schedules, each once, in the order the story's block lists them.
fn scheduled(state: *anyopaque, a: std.mem.Allocator) error{OutOfMemory}![]const river.Running.Form {
    const st: *State = @ptrCast(@alignCast(state));
    const found = st.story.block(tide.block.name) orelse return &.{};
    // the block was read once already, when the time was loaded
    const plan = tide.block.read(a, found.bytes) catch return &.{};
    var out: std.ArrayList(river.Running.Form) = .empty;
    outer: for (plan.schedules) |p| {
        const name = st.story.section(.fromRaw(p.section)).name;
        for (out.items) |f| if (std.mem.eql(u8, f.object, name)) continue :outer;
        try out.append(a, .{ .object = name });
    }
    return out.items;
}

fn cancel(state: *anyopaque, form: usize, _: []const facts.Value, told: *river.Running.Told) error{ OutOfMemory, Refused, Stopped }!void {
    const st: *State = @ptrCast(@alignCast(state));
    const name = (try scheduled(state, told.arena))[form].object;
    const section = st.story.sectionNamed(name).?;
    if (st.tide.cancelKey(section.raw()) == 0) return told.refuse("`{s}` is on the calendar no more: it came due for the last time, or was cancelled", .{name});
    try told.say(.{ .what = "cancelled", .name = name });
}

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
                try told.arena.print("{d} times from {s} {d}, told as one", .{ d.count, name, d.at })
            else
                try told.arena.print("at {s} {d}", .{ name, d.at });
            try told.say(.{ .what = "due", .name = st.story.section(section).name, .words = &.{when}, .section = section });
        }
        if (moved.left == 0) return true;
        left = moved.left;
    }
}
