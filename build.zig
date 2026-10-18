const std = @import("std");
const riverrun = @import("riverrun");

/// What a host that depends on tide builds: the `tide` module, on riverrun's runtime. tide's compiler side,
/// `tide-compiler`, is `compiler`'s to make, on first ask, so a game that only keeps time never fetches riverrun's
/// compiler. The tests and the gate are `dev`'s.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = b.addModule("tide", .{
        .root_source_file = b.path("src/tide.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports(b, target, optimize),
    });
}

/// tide's compiler side, `tide-compiler`, of the tide instance `dep`: what a story's vocabulary registers,
/// `tide.package` (the `calendar` kind, the schedule's tags, tide's check and the pass that writes its block), on
/// the riverrun compiler of the riverrun instance tide's own build stands on. Made on the first ask and kept with
/// the instance; null until riverrun's compiler is fetched. A story's build asks it of tide asked by
/// `riverrun.building(b)`, and hands it to `riverrun.addStory` as `tide-compiler`.
pub fn compiler(dep: *std.Build.Dependency) ?*std.Build.Module {
    const d = dep.builder;
    if (d.modules.get("tide-compiler")) |m| return m;
    const runtime = dep.module("tide");
    const target = runtime.resolved_target.?;
    const optimize = runtime.optimize.?;
    const river = d.dependency("riverrun", .{ .target = target, .optimize = optimize });
    return d.addModule("tide-compiler", .{
        .root_source_file = d.path("src/front.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "riverrun-compiler", .module = riverrun.compiler(river) orelse return null },
            .{ .name = "riverrun", .module = river.module("riverrun") },
            .{ .name = "tide", .module = runtime },
        },
    });
}

/// tide's development: its tests under preflight's gate, the compiler side's beside the runtime's. Run through bay.
pub fn dev(b: *std.Build, tools: type) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Select tests by name");
    const package = b.dependency("tide", .{ .target = target, .optimize = optimize });
    const filters: []const []const u8 = if (test_filter) |filter| &.{filter} else &.{};
    const test_step = b.step("test", "Run the tests");
    const runtime_tests = b.addTest(.{ .name = "tide-tests", .filters = filters, .root_module = package.module("tide") });
    test_step.dependOn(&b.addRunArtifact(runtime_tests).step);
    const front = compiler(package) orelse return;
    const front_tests = b.addTest(.{ .name = "tide-compiler-tests", .filters = filters, .root_module = front });
    test_step.dependOn(&b.addRunArtifact(front_tests).step);
    // the vocabulary a game would give addStory, on the riverrun compiler tide's compiler side stands on
    const vocabulary = b.createModule(.{
        .root_source_file = package.path("tools/vocabulary.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "riverrun-compiler", .module = front.import_table.get("riverrun-compiler").? }, .{ .name = "tide-compiler", .module = front } },
    });
    const vocabulary_tests = b.addTest(.{ .name = "tide-vocabulary-tests", .filters = filters, .root_module = vocabulary });
    test_step.dependOn(&b.addRunArtifact(vocabulary_tests).step);
    tools.preflight.addCi(b, package.builder, .{ .tests = test_step });
}

fn imports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) []const std.Build.Module.Import {
    const aegis = b.dependency("aegis", .{ .target = target, .optimize = optimize });
    const river = b.dependency("riverrun", .{ .target = target, .optimize = optimize });
    return b.allocator.dupe(std.Build.Module.Import, &.{
        .{ .name = "aegis", .module = aegis.module("aegis") },
        .{ .name = "riverrun", .module = river.module("riverrun") },
    }) catch @panic("OOM");
}
