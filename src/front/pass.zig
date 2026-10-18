//! tide in a story's build: its problems reported where they are written,
//! and its block written into the compiled story.

const std = @import("std");
const riverrun = @import("riverrun-compiler");
const tide = @import("tide");
const read_ = @import("read.zig");

const syntax = riverrun.syntax;
const check_ = riverrun.check;
const compile = riverrun.compile;
const block = tide.block;

/// Reports what does not hold together in `checked`'s time, at the place it is written. A tool that reads and
/// checks a story runs this between checking and compiling, so a typo in a calendar fails with its line.
pub fn check(gpa: std.mem.Allocator, diags: *syntax.Diagnostics, checked: *const check_.Checked) error{OutOfMemory}!void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const r = try read_.read(gpa, arena.allocator(), checked);
    for (r.problems) |p| try diags.add(gpa, p.span, .err, "{s}", .{p.message});
}

/// The pass a game's vocabulary registers: tide's block, in the compiled story's ids.
pub const pass: compile.Pass = .{ .run = run };

fn run(_: ?*anyopaque, c: *compile.Compiler) compile.Compiler.Error!void {
    const r = try read_.read(c.gpa, c.arena, c.checked);
    // a compile pass cannot say where: `check` says it, and the build refuses the story here
    if (r.problems.len > 0) return error.PassFailed;
    // a story that declares no time has no block, and `fromStory` says so
    if (r.plan.clocks.len == 0 and r.plan.calendars.len == 0 and r.plan.schedules.len == 0) return;
    const plan = try remap(c, r);
    const bytes = try block.write(c.gpa, plan);
    defer c.gpa.free(bytes);
    try c.b.block(block.name, block.version, bytes);
}

fn fact(c: *const compile.Compiler, raw: u16) u16 {
    if (raw == block.none16) return raw;
    return c.fact(.fromRaw(raw)).raw();
}

// The checker's ids in the plan, made the compiled story's.
fn remap(c: *compile.Compiler, r: read_.Read) compile.Compiler.Error!block.Plan {
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
        .part => |p| (c.part(p) orelse return error.PassFailed).raw(),
    };
    return .{ .clocks = clocks, .calendars = cals, .derived = derived, .schedules = scheds };
}
