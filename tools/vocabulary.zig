//! A game's vocabulary for riverrun's `addStory`, with tide registered
//! beside the game's own tags: what tide's development compiles its school
//! year with, as a game's build would.

const riverrun = @import("riverrun-compiler");
const tide = @import("tide-compiler");

// the game's own: a section the phone shows
const schema: riverrun.check.Schema = .{ .keys = &.{.{ .name = "phone", .on = .{ .section = true } }} };

pub const options: riverrun.check.Options = .{ .schema = &schema };
pub const packages: []const riverrun.Package = &.{tide.package};
