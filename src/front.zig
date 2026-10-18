//! tide's compiler side: what it adds to a story's language and its build.
//! A game's vocabulary registers `kind`, adds `schedule(…)` to its schema and
//! `pass` to its passes; a tool that checks stories also runs `check`. Only a
//! build needs this; at run time `tide.fromStory` reads what `pass` wrote.

const vocabulary = @import("front/vocabulary.zig");
const pass_ = @import("front/pass.zig");

pub const kind = vocabulary.kind;
pub const schedule = vocabulary.schedule;
pub const pass = pass_.pass;
pub const check = pass_.check;
pub const read = @import("front/read.zig");

test {
    _ = vocabulary;
    _ = pass_;
    _ = read;
    _ = @import("front/front_test.zig");
}
