//! A school year compiled while tide builds, through riverrun's `addStory`
//! with tide registered as a game registers it, embedded, loaded and told:
//! the game's riverrun, tide's and the story's are one.

const std = @import("std");
const riverrun = @import("riverrun");
const tide = @import("tide");
const story = @import("story");

test "a story compiled by addStory with tide registered keeps its time and is told" {
    const gpa = std.testing.allocator;
    const s: riverrun.story.Story = try .init(story.graph, .{});
    const words: riverrun.story.Strings = try .init(story.words, .{});
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var memory: riverrun.facts.Memory = try .init(gpa, try s.schema(arena.allocator()));
    defer memory.deinit();
    var t = try tide.fromStory(gpa, &s, memory.store(), .{});
    defer t.deinit();
    try t.sync();
    var due: [8]tide.Due = undefined;
    // six days and three slots: Sunday evening
    try std.testing.expectEqual(@as(usize, 1), (try t.advance(t.clockNamed("turn").?, 27, &due)).due.len);
    try std.testing.expectEqual(@as(u64, s.sectionNamed("ramen").?.raw()), due[0].key);
    var session: riverrun.run.Session = try .init(gpa, &s, &words, memory.store(), &riverrun.run.Host.none, .{});
    defer session.deinit();
    try session.start(.fromRaw(0), s.sectionNamed("ramen").?);
    try std.testing.expectEqualStrings("yo. ramen?", (try session.next(.fromRaw(0))).line.text);
}
