//! A compiled story's time, loaded: tide's block read, checked against the
//! story it came with, and turned into the declarations `Tide.init` takes,
//! with each schedule the story declared taken. The names (clocks', units',
//! places') are the story's own, read from it, so nothing is said twice.

const std = @import("std");
const riverrun = @import("riverrun");
const block = @import("block.zig");
const calendar = @import("calendar.zig");
const Tide = @import("Tide.zig");

const story = riverrun.story;
const facts = riverrun.facts;

pub const Options = struct {
    /// How many schedules may be held at once, the story's own among them.
    room: u32 = 1024,
};

pub const Error = Tide.Error || block.Error || error{
    /// The story has no tide block: nothing in it declares time.
    NoTime,
    /// The block is of another version than this tide reads.
    WrongVersion,
    /// The block names a fact or a section the story does not have, or a fact of the wrong kind.
    NotThisStory,
};

/// The time `s` declares, its facts written through `store`. The tide owns what it read and frees it on `deinit`.
pub fn fromStory(gpa: std.mem.Allocator, s: *const story.Story, store: ?facts.Store, options: Options) Error!Tide {
    const found = s.block(block.name) orelse return error.NoTime;
    if (found.version != block.version) return error.WrongVersion;
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = .init(gpa);
    var owned = true;
    defer if (owned) {
        arena.deinit();
        gpa.destroy(arena);
    };
    const a = arena.allocator();
    const plan = try block.read(a, found.bytes);
    var t: Tide = try .init(gpa, .{
        .clocks = try clocks(a, s, plan),
        .calendars = try calendars(a, s, plan),
        .derived = try derived(a, s, plan),
        .room = options.room,
        .store = store,
    });
    t.owned = arena;
    owned = false;
    errdefer t.deinit();
    for (plan.schedules) |p| try take(&t, s, p);
    return t;
}

fn take(t: *Tide, s: *const story.Story, p: block.Schedule) Error!void {
    if (p.section >= s.len(.sections) or p.clock >= t.clocks.len) return error.NotThisStory;
    const clock: Tide.ClockId = .fromRaw(p.clock);
    const every = p.every orelse {
        _ = try t.at(clock, p.first, p.section);
        return;
    };
    _ = try t.every(clock, .{ .first = p.first, .every = every, .times = p.times, .policy = p.policy }, p.section);
}

const Want = enum {
    int,
    /// A place: a `one of` where it has names, an int where its places are numbers.
    place,
};

fn factOf(s: *const story.Story, raw: u16, want: Want) Error!facts.FactId {
    if (raw >= s.len(.facts)) return error.NotThisStory;
    const id: facts.FactId = .fromRaw(raw);
    const d = s.fact(id);
    const ok = switch (want) {
        .int => d.kind == .int,
        .place => d.kind == .int or (d.kind == .one_of and d.enumeration != null),
    };
    if (!ok) return error.NotThisStory;
    return id;
}

fn optional(s: *const story.Story, raw: u16, want: Want) Error!?facts.FactId {
    if (raw == block.none16) return null;
    return try factOf(s, raw, want);
}

// The values of a `one of`, which name a unit's or a cycle's places; none where the places are numbers.
fn names(a: std.mem.Allocator, s: *const story.Story, place: ?facts.FactId) Error![]const []const u8 {
    const id = place orelse return &.{};
    if (s.fact(id).kind == .int) return &.{};
    const r = s.items(s.fact(id).enumeration.?);
    const out = try a.alloc([]const u8, r.len);
    for (out, 0..) |*n, k| n.* = s.item(r.start + @as(u32, @intCast(k))); // safe: an enumeration's few values
    return out;
}

fn clocks(a: std.mem.Allocator, s: *const story.Story, plan: block.Plan) Error![]const Tide.ClockDecl {
    const out = try a.alloc(Tide.ClockDecl, plan.clocks.len);
    for (out, plan.clocks) |*c, raw| {
        const id = try factOf(s, raw, .int);
        c.* = .{ .name = s.fact(id).name, .fact = id };
    }
    return out;
}

fn calendars(a: std.mem.Allocator, s: *const story.Story, plan: block.Plan) Error![]const Tide.CalendarDecl {
    const out = try a.alloc(Tide.CalendarDecl, plan.calendars.len);
    for (out, plan.calendars) |*c, p| {
        if (p.section >= s.len(.sections)) return error.NotThisStory;
        const units = try a.alloc(calendar.Unit, p.units.len);
        const counts = try a.alloc(?facts.FactId, p.units.len);
        const places = try a.alloc(?facts.FactId, p.units.len);
        for (units, counts, places, p.units) |*u, *count, *place, pu| {
            place.* = try optional(s, pu.place, .place);
            count.* = try optional(s, pu.count, .int);
            u.* = .{ .name = pu.name, .size = switch (pu.size) {
                .fixed => |n| .{ .fixed = n },
                .cycle => |sizes| .{ .cycle = sizes },
            }, .names = try names(a, s, place.*) };
        }
        const cycles = try a.alloc(calendar.Cycle, p.cycles.len);
        const cycle_places = try a.alloc(?facts.FactId, p.cycles.len);
        for (cycles, cycle_places, p.cycles) |*y, *place, py| {
            place.* = try optional(s, py.place, .place);
            y.* = .{ .name = py.name, .unit = py.unit, .length = py.length, .offset = py.offset, .names = try names(a, s, place.*) };
        }
        c.* = .{
            .clock = .fromRaw(p.clock),
            .decl = .{ .name = s.section(.fromRaw(p.section)).name, .units = units, .cycles = cycles, .start = p.start },
            .binding = .{ .counts = counts, .places = places, .cycles = cycle_places },
        };
    }
    return out;
}

fn per(p: block.Per) Tide.Per {
    return switch (p) {
        .ticks => |n| .{ .ticks = n },
        .unit => |u| .{ .unit = .{ .calendar = .fromRaw(u.calendar), .unit = u.unit } },
    };
}

fn derived(a: std.mem.Allocator, s: *const story.Story, plan: block.Plan) Error![]const Tide.Derived {
    const out = try a.alloc(Tide.Derived, plan.derived.len);
    for (out, plan.derived) |*d, p| {
        const fact = try factOf(s, p.fact, .int);
        d.* = .{ .fact = fact, .what = switch (p.what) {
            .until => |m| .{ .until = .{ .clock = .fromRaw(m.clock), .at = m.at, .per = per(m.per) } },
            .since => |m| .{ .since = .{ .clock = .fromRaw(m.clock), .at = m.at, .per = per(m.per) } },
            .drift => |m| .{ .drift = .{ .a = .fromRaw(m.a), .b = .fromRaw(m.b), .per = m.per } },
        } };
    }
    return out;
}
