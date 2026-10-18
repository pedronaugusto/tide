const std = @import("std");

/// What a host that depends on tide builds: the `tide` module. The tests and
/// the gate are `dev`'s.
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

/// tide's development: its tests under preflight's gate. Run through bay.
pub fn dev(b: *std.Build, tools: type) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Select tests by name");
    const package = b.dependency("tide", .{ .target = target, .optimize = optimize });
    const p = package.builder;
    const filters: []const []const u8 = if (test_filter) |filter| &.{filter} else &.{};
    const test_step = b.step("test", "Run the tests");
    const tests = b.addTest(.{
        .name = "tide-tests",
        .filters = filters,
        .root_module = b.createModule(.{
            .root_source_file = p.path("src/tide.zig"),
            .target = target,
            .optimize = optimize,
            .imports = imports(p, target, optimize),
        }),
    });
    test_step.dependOn(&b.addRunArtifact(tests).step);
    tools.preflight.addCi(b, p, .{ .tests = test_step });
}

fn imports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) []const std.Build.Module.Import {
    const aegis = b.dependency("aegis", .{ .target = target, .optimize = optimize });
    const riverrun = b.dependency("riverrun", .{ .target = target, .optimize = optimize });
    return b.allocator.dupe(std.Build.Module.Import, &.{
        .{ .name = "aegis", .module = aegis.module("aegis") },
        .{ .name = "riverrun", .module = riverrun.module("riverrun") },
    }) catch @panic("OOM");
}
