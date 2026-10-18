//! A game's vocabulary for riverrun's `addStory`, with tide registered beside
//! the game's own tags: the `calendar` kind, the schedule tags keyed by the
//! calendar's facts, and the pass that writes tide's block.

const std = @import("std");
const riverrun = @import("riverrun-compiler");
const tide = @import("tide-compiler");

const Key = riverrun.check.Schema.Key;

// the game's own: a section the phone shows
const game = [_]Key{.{ .name = "phone", .on = .{ .section = true } }};
const schema: riverrun.check.Schema = .{ .keys = &(game ++ tide.schedule(&.{ "slot", "weekday" }, &.{"day"})) };

pub const options: riverrun.check.Options = .{ .schema = &schema, .kinds = &.{tide.kind} };
pub const passes: []const riverrun.compile.Pass = &.{tide.pass};

test "a game's tags and tide's are one schema" {
    try std.testing.expect(schema.find("phone", .section) == .found);
    try std.testing.expect(schema.find("weekday", .section) == .found);
    try std.testing.expect(schema.find("every", .part) == .found);
    try std.testing.expectEqualStrings("calendar", options.kinds[0].name);
    try std.testing.expectEqual(@as(usize, 1), passes.len);
}
