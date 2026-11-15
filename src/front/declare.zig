//! The facts a calendar keeps, declared by its section as the story's own
//! are: each unit's and cycle's `place` (one of its `names`, or a number
//! where it has none), each unit's `count`, and each time fact the
//! calendar keeps, an int named by its part. All are the game's, written by
//! tide, in the scope the calendar's `scope` names.

const std = @import("std");
const riverrun = @import("riverrun-compiler");
const written = @import("written.zig");

const ast = riverrun.syntax.ast;
const Declared = riverrun.check.Declared;

/// What a `(calendar)` section brings into the story: `Kind.declare`.
pub fn declare(a: std.mem.Allocator, s: *const ast.Section, _: []const ast.File) error{OutOfMemory}![]const Declared {
    var out: std.ArrayList(Declared) = .empty;
    const scope: ?[]const u8 = if (written.tagOf(s.tags, "scope")) |t| written.only(t) else null;
    for (s.subsections) |*p| switch (written.what(p)) {
        // a tag with no fact's name declares nothing; the checker says it takes one
        .unit, .cycle => {
            if (written.tagOf(p.tags, "place")) |t| if (t.values.len > 0) try out.append(a, try place(a, scope, t, written.tagOf(p.tags, "names")));
            if (written.tagOf(p.tags, "count")) |t| if (t.values.len > 0) try out.append(a, int(scope, .{ .text = written.only(t), .span = t.at(0) }));
        },
        .derived => try out.append(a, int(scope, p.name)),
        .other => {},
    };
    return out.items;
}

fn int(scope: ?[]const u8, name: ast.Name) Declared {
    return .{ .scope = scope, .fact = .{ .span = name.span, .name = name, .type = .int, .game = true } };
}

// `[place weekday] [names monday, …]`: one of the names, each where it is written, and the fact where its name is.
fn place(a: std.mem.Allocator, scope: ?[]const u8, t: *const ast.Tag, names: ?*const ast.Tag) error{OutOfMemory}!Declared {
    const name: ast.Name = .{ .text = written.only(t), .span = t.at(0) };
    const list = names orelse return int(scope, name);
    if (list.values.len == 0) return int(scope, name);
    const values = try a.alloc(ast.Name, list.values.len);
    for (values, list.values, 0..) |*v, n, i| v.* = .{ .text = n, .span = list.at(i) };
    return .{ .scope = scope, .fact = .{ .span = t.span, .name = name, .type = .{ .one_of = values }, .game = true } };
}
