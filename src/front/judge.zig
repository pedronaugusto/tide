//! tide's judges: each tag tide defines held to the calendar it is
//! written against, and refused in tide's words where its value is
//! written, or at the tag for an instant of several words. A calendar's
//! own tags are judged against it; a schedule's against the calendar it
//! means, and where it means none, or several, tide's check says so once.

const std = @import("std");
const riverrun = @import("riverrun-compiler");
const written = @import("written.zig");

const check = riverrun.check;
const Checker = check.Checker;
const Tagged = check.Schema.Tagged;
const Error = Checker.Error;

/// `clock turn`, `drift ship`: a `(clock)` fact.
pub fn clock(c: *Checker, t: Tagged) Error!void {
    const name = written.only(t.tag);
    if (c.valueNamed(t.module, name)) |named| if (named == .fact and c.facts.items[named.fact.raw()].clock) return;
    try c.err(t.tag.at(0), "`{s}` is not a `(clock)` fact", .{name});
}

/// `cycle day`: a unit of this calendar.
pub fn cycle(c: *Checker, t: Tagged) Error!void {
    const s = c.section(t.section.?);
    if (written.numbered(s.node, .unit, written.only(t.tag)) != null) return;
    try c.err(t.tag.at(0), "`{s}` is not a unit of this calendar", .{written.only(t.tag)});
}

/// `per day` or `per 4`: a unit of this calendar, or a number of ticks; for a drift, a unit of fixed size.
pub fn per(c: *Checker, t: Tagged) Error!void {
    const s = c.section(t.section.?).node;
    const v = written.only(t.tag);
    if (written.number(v)) |n| {
        if (n == 0) try c.err(t.tag.at(0), "`per` counts in ticks above zero", .{});
        return;
    }
    const u = written.numbered(s, .unit, v) orelse return c.err(t.tag.at(0), "`{s}` is not a unit of this calendar, nor a number of ticks", .{v});
    if (written.tagOf(t.beside, "drift") == null) return;
    // a drift counts ticks, so every unit up to `per`'s has one size
    for (0..@as(usize, u) + 1) |level| {
        const size = written.tagOf(written.nth(s, .unit, level).?.tags, "size").?;
        if (size.values.len != 1) return c.err(t.tag.at(0), "a drift is counted in ticks: `{s}` has no fixed size", .{v});
    }
}

/// `until day 34`, `since day 2`: an instant of this calendar.
pub fn instant(c: *Checker, t: Tagged) Error!void {
    try words(c, t, c.section(t.section.?).node);
}

/// `at sunday evening`: an instant of the calendar the schedule means.
pub fn at(c: *Checker, t: Tagged) Error!void {
    const i = written.calendarFor(c.sections.items, t.beside) orelse return;
    try words(c, t, c.sections.items[i].node);
}

fn words(c: *Checker, t: Tagged, s: *const riverrun.syntax.ast.Section) Error!void {
    switch (try written.instant(c.arena, s, t.tag.values)) {
        .instant => {},
        .problem => |p| try c.err(t.tag.key.span, "{s}", .{p}),
    }
}

/// `every week`: a unit or a cycle of the calendar the schedule means.
pub fn every(c: *Checker, t: Tagged) Error!void {
    const i = written.calendarFor(c.sections.items, t.beside) orelse return;
    const s = c.sections.items[i].node;
    const v = written.only(t.tag);
    if (written.numbered(s, .unit, v) != null or written.numbered(s, .cycle, v) != null) return;
    try c.err(t.tag.at(0), "`{s}` is not a unit or a cycle of this calendar", .{v});
}

/// `calendar school`: a `(calendar)` section.
pub fn calendar(c: *Checker, t: Tagged) Error!void {
    for (c.sections.items) |s| if (written.isCalendar(s) and std.mem.eql(u8, s.name, written.only(t.tag))) return;
    try c.err(t.tag.at(0), "`{s}` is not a calendar", .{written.only(t.tag)});
}
