//! The vocabulary of the game the time chapter's stories are written for:
//! the ferry at Hollin, as riverrun's manual has it, with tide registered so
//! that a story may keep a calendar and schedule its scenes. Your game has
//! its own.

const riverrun = @import("riverrun-compiler");
const tide = @import("tide-compiler");

// the game's subtitles hold 100 columns, and its choices 40
const width: riverrun.check.Width = .{ .line = 100, .choice = 40 };

pub const options: riverrun.check.Options = .{ .width = width };

// the packages the game runs: tide, for its time
pub const packages: []const riverrun.Package = &.{tide.package};
