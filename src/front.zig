//! tide's compiler side: what it adds to a story's language and its build,
//! registered as one package. A game's vocabulary lists `package`, and its
//! build hands this module to `addStory` from tide's `compiler`; the
//! calendar's facts, tide's judges, its check and its pass come with it.
//! Only a build needs this; at run time `tide.fromStory` reads what the pass
//! wrote.

const vocabulary = @import("front/vocabulary.zig");

/// What a vocabulary registers: `pub const packages = &.{tide.package}`.
pub const package = vocabulary.package;
/// The `calendar` kind and the schedule's tags, for a vocabulary that composes its own package from tide's.
pub const kind = vocabulary.kind;
pub const keys = vocabulary.keys;
/// A checked story's time, as tide's pass reads it, for tools.
pub const read = @import("front/read.zig");

test {
    _ = vocabulary;
    _ = read;
    _ = @import("front/written.zig");
    _ = @import("front/front_test.zig");
    _ = @import("front/running.zig");
}
