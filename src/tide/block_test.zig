//! The block's promises: a plan written reads back as itself, and a reader
//! that never trusts the bytes reads any bytes to a plan or to `Malformed`,
//! refusing a block that does not end where its last record does.
const std = @import("std");
const shakedown = @import("shakedown");
const block = @import("block.zig");
const calendar = @import("calendar.zig");

const testing = std.testing;

/// A plan within the block's bounds.
fn plan(s: *shakedown.Source, a: std.mem.Allocator) !block.Plan {
    const gen = shakedown.gen;
    var p = try gen.any(s, block.Plan, a);
    if (p.clocks.len > block.max_clocks) p.clocks = p.clocks[0..block.max_clocks];
    if (p.calendars.len > block.max_calendars) p.calendars = p.calendars[0..block.max_calendars];
    if (p.derived.len > block.max_derived) p.derived = p.derived[0..block.max_derived];
    const cals = try a.dupe(block.Cal, p.calendars);
    for (cals) |*c| {
        if (c.units.len > calendar.max_units) c.units = c.units[0..calendar.max_units];
        if (c.cycles.len > calendar.max_cycles) c.cycles = c.cycles[0..calendar.max_cycles];
        const units = try a.dupe(block.Unit, c.units);
        for (units) |*u| switch (u.size) {
            .cycle => |sizes| if (sizes.len > block.max_sizes) {
                u.size = .{ .cycle = sizes[0..block.max_sizes] };
            },
            .fixed => {},
        };
        c.units = units;
    }
    p.calendars = cals;
    return p;
}

test "any plan written reads back as itself" {
    try shakedown.check(testing.allocator, {}, struct {
        fn one(_: void, case: *shakedown.Case) anyerror!void {
            var state: std.heap.ArenaAllocator = .init(testing.allocator);
            defer state.deinit();
            const a = state.allocator();
            const p = try plan(case.source, a);
            const bytes = try block.write(a, p);
            const back = block.read(a, bytes) catch |err| {
                // A plan the generator made past a bound the reader holds
                // is the writer's to refuse too: none may read as malformed.
                std.debug.print("written plan refused: {s}\n", .{@errorName(err)});
                return err;
            };
            try testing.expectEqualDeep(p, back);
        }
    }.one, .{ .cases = 2000, .seed = 0xb10c });
}

test "any bytes read to a plan or Malformed, and a block reads whole or not at all" {
    try shakedown.check(testing.allocator, {}, struct {
        fn one(_: void, case: *shakedown.Case) anyerror!void {
            var state: std.heap.ArenaAllocator = .init(testing.allocator);
            defer state.deinit();
            const a = state.allocator();
            const bytes = try block.write(a, try plan(case.source, a));
            var buffer: [1024]u8 = undefined;
            const mutated = shakedown.gen.mutated(case.source, &buffer, &.{bytes});
            _ = block.read(a, mutated) catch |err| switch (err) {
                error.Malformed => {},
                error.OutOfMemory => return err,
            };
            // A byte past the last record is refused, as is any cut.
            const longer = try std.mem.concat(a, u8, &.{ bytes, "\x00" });
            try testing.expectError(error.Malformed, block.read(a, longer));
            if (bytes.len > 0) try testing.expectError(error.Malformed, block.read(a, bytes[0 .. bytes.len - 1]));
        }
    }.one, .{ .cases = 3000, .seed = 0xb10d });
}
