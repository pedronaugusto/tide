//! tide in a story's build: its problems reported inside riverrun's check,
//! where they are written, and its block written into the compiled story.

const std = @import("std");
const riverrun = @import("riverrun-compiler");
const tide = @import("tide");
const read_ = @import("read.zig");

const check_ = riverrun.check;
const compile_ = riverrun.compile;
const block = tide.block;

/// tide's check of the whole story, which riverrun's check runs once its own are done: what only the whole of a
/// calendar or a schedule shows, at the place it is written.
pub fn check(_: ?*anyopaque, c: *check_.Checker, story: *const check_.Checked) error{OutOfMemory}!void {
    var arena: std.heap.ArenaAllocator = .init(c.gpa);
    defer arena.deinit();
    const r = try read_.read(c.gpa, arena.allocator(), story);
    for (r.problems) |p| try c.err(p.span, "{s}", .{p.message});
}

/// tide's compile pass: its block, in the compiled story's ids.
pub fn compile(_: ?*anyopaque, c: *compile_.Compiler) compile_.Compiler.Error!void {
    const r = try read_.read(c.gpa, c.arena, c.checked);
    // what tide's check refused never reaches here; said again, it refuses the story where it is written
    for (r.problems) |p| try c.err(p.span, "{s}", .{p.message});
    if (r.problems.len > 0) return error.PassFailed;
    // a story that declares no time has no block, and `fromStory` says so
    if (r.plan.clocks.len == 0 and r.plan.calendars.len == 0 and r.plan.schedules.len == 0) return;
    const plan = try remap(c, r);
    const bytes = try block.write(c.gpa, plan);
    defer c.gpa.free(bytes);
    try c.b.block(block.name, block.version, bytes);
}

fn fact(c: *const compile_.Compiler, raw: u16) u16 {
    if (raw == block.none16) return raw;
    return c.fact(.fromRaw(raw)).raw();
}

// The checker's ids in the plan, made the compiled story's.
fn remap(c: *compile_.Compiler, r: read_.Read) compile_.Compiler.Error!block.Plan {
    const a = c.arena;
    const clocks = try a.alloc(u16, r.plan.clocks.len);
    for (clocks, r.plan.clocks) |*out, raw| out.* = fact(c, raw);
    const cals = try a.alloc(block.Cal, r.plan.calendars.len);
    for (cals, r.plan.calendars) |*out, in| {
        out.* = in;
        out.section = c.section(.fromRaw(@intCast(in.section))).raw(); // safe: the reader wrote a checker's section id
        const units = try a.dupe(block.Unit, in.units);
        for (units) |*u| {
            u.place = fact(c, u.place);
            u.count = fact(c, u.count);
        }
        const cycles = try a.dupe(block.Cycle, in.cycles);
        for (cycles) |*y| y.place = fact(c, y.place);
        out.units = units;
        out.cycles = cycles;
    }
    const derived = try a.dupe(block.Derived, r.plan.derived);
    for (derived) |*d| d.fact = fact(c, d.fact);
    const scheds = try a.dupe(block.Schedule, r.plan.schedules);
    for (scheds, r.targets) |*s, t| s.section = switch (t) {
        .section => |id| c.section(id).raw(),
        .part => |p| (c.part(p) orelse unreachable).raw(), // unreachable: the reader refuses a schedule on a candidate or a rule, which compile to no section
    };
    return .{ .clocks = clocks, .calendars = cals, .derived = derived, .schedules = scheds };
}
