const std = @import("std");

/// What a host that depends on tide builds: the `tide` module, on riverrun's runtime. A build that passes
/// `.compiler = true` gets `tide-compiler` too, what a game's story build registers (the `calendar` kind, the
/// schedule tags, the pass that writes tide's block), on riverrun's compiler. The tests and the gate are `dev`'s.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const compiler = b.option(bool, "compiler", "Offer the tide-compiler module") orelse false;
    const riverrun = b.dependency("riverrun", .{ .target = target, .optimize = optimize, .compiler = compiler });
    const runtime = b.addModule("tide", .{
        .root_source_file = b.path("src/tide.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports(b, riverrun, target, optimize),
    });
    if (!compiler) return;
    // riverrun's compiler depends on lazy packages: absent until fetched, after which the build runs again
    const river_compiler = riverrun.builder.modules.get("riverrun-compiler") orelse return;
    _ = b.addModule("tide-compiler", .{
        .root_source_file = b.path("src/front.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "riverrun-compiler", .module = river_compiler },
            .{ .name = "riverrun", .module = riverrun.module("riverrun") },
            .{ .name = "tide", .module = runtime },
        },
    });
}

/// tide's development: its tests under preflight's gate, the compiler side's beside the runtime's. Run through bay.
pub fn dev(b: *std.Build, tools: type) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Select tests by name");
    const package = b.dependency("tide", .{ .target = target, .optimize = optimize, .compiler = true });
    const filters: []const []const u8 = if (test_filter) |filter| &.{filter} else &.{};
    const test_step = b.step("test", "Run the tests");
    const runtime = package.module("tide");
    const front = package.builder.modules.get("tide-compiler") orelse return;
    const river_compiler = front.import_table.get("riverrun-compiler").?;
    const runtime_tests = b.addTest(.{ .name = "tide-tests", .filters = filters, .root_module = runtime });
    test_step.dependOn(&b.addRunArtifact(runtime_tests).step);
    const front_tests = b.addTest(.{ .name = "tide-compiler-tests", .filters = filters, .root_module = front });
    test_step.dependOn(&b.addRunArtifact(front_tests).step);
    // the vocabulary a game would give addStory, built as addStory builds one, with tide's beside riverrun's
    const vocabulary = b.createModule(.{
        .root_source_file = package.path("tools/vocabulary.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "riverrun-compiler", .module = river_compiler }, .{ .name = "tide-compiler", .module = front } },
    });
    const vocabulary_tests = b.addTest(.{ .name = "tide-vocabulary-tests", .filters = filters, .root_module = vocabulary });
    test_step.dependOn(&b.addRunArtifact(vocabulary_tests).step);
    tools.preflight.addCi(b, package.builder, .{ .tests = test_step });
}

fn imports(b: *std.Build, riverrun: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) []const std.Build.Module.Import {
    const aegis = b.dependency("aegis", .{ .target = target, .optimize = optimize });
    return b.allocator.dupe(std.Build.Module.Import, &.{
        .{ .name = "aegis", .module = aegis.module("aegis") },
        .{ .name = "riverrun", .module = riverrun.module("riverrun") },
    }) catch @panic("OOM");
}
