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

/// tide's development: its tests under preflight's gate, the compiler side's beside the runtime's, and a school
/// year compiled through `addStory` with tide registered, as a game's build compiles one. Run through bay.
pub fn dev(b: *std.Build, tools: type) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Select tests by name");
    const package = b.dependency("tide", .{ .target = target, .optimize = optimize });
    const filters: []const []const u8 = if (test_filter) |filter| &.{filter} else &.{};
    const test_step = b.step("test", "Run the tests");
    const runtime_tests = b.addTest(.{ .name = "tide-tests", .filters = filters, .root_module = package.module("tide") });
    // The block's properties: shakedown, in the development graph alone.
    runtime_tests.root_module.addImport("shakedown", b.dependency("shakedown", .{ .target = target, .optimize = optimize }).module("shakedown"));
    test_step.dependOn(&b.addRunArtifact(runtime_tests).step);
    const front_tests = b.addTest(.{ .name = "tide-compiler-tests", .filters = filters, .root_module = compiler(package) orelse return });
    // The whole compiler's property: riverrun's tools put a story through all of it, fuzzed by shakedown.
    front_tests.root_module.addImport("shakedown", b.dependency("shakedown", .{ .target = target, .optimize = optimize }).module("shakedown"));
    front_tests.root_module.addImport("riverrun-tools", riverrun.tools(package.builder.dependency("riverrun", .{ .target = target, .optimize = optimize })) orelse return);
    test_step.dependOn(&b.addRunArtifact(front_tests).step);
    test_step.dependOn(&b.addRunArtifact(storyTests(b, package, filters) orelse return).step);
    docs(b, test_step) orelse return;
    tools.preflight.addCi(b, package.builder, .{ .tests = test_step });
}

/// The stories tide's documentation shows: each checked by `riverrun check` with the game's vocabulary of tide's
/// development, and every story the documents show rows of one of them.
const documented = struct {
    const stories = [_][]const u8{"src/front/testdata/school.river"};
    const documents = [_][]const u8{ "docs/design.md", "src/front/written.zig", "src/front/vocabulary.zig" };
};

/// What `riverrun play` writes for the school year under `tools/testdata/school.play`.
const school_played =
    \\== ramen
    \\  [every week] [at sunday evening] [times 5]
    \\-> end
    \\> :facts
    \\  slot = morning
    \\  weekday = monday
    \\  days_left = 34
    \\> :wait 27
    \\! due ramen
    \\  at turn 27
    \\RYUJI: yo. ramen?
    \\-> end
    \\> :facts
    \\  turn = 27
    \\  slot = evening
    \\  day = 6
    \\  weekday = sunday
    \\  days_left = 28
    \\> :wait 28
    \\! due ramen
    \\  at turn 55
    \\RYUJI: yo. ramen?
    \\-> end
    \\
;

fn docs(b: *std.Build, test_step: *std.Build.Step) ?void {
    const package = b.dependency("tide", riverrun.building(b));
    const river = b.dependency("riverrun", riverrun.building(b));
    const program = riverrun.addProgram(b, river, .{
        .vocabulary = package.path("tools/vocabulary.zig"),
        .packages = &.{.{ .name = "tide-compiler", .module = compiler(package) orelse return null }},
    });
    for (documented.stories) |story| test_step.dependOn(&riverrun.addCheck(b, program, &.{package.path(story)}, .{}).step);
    // the school year played as a game plays it, its time kept by tide: the transcript pinned
    const played = b.addRunArtifact(program);
    played.addArgs(&.{ "play", "--script" });
    played.addFileArg2(package.path("tools/testdata/school.play"), .{});
    played.addFileArg2(package.path("src/front/testdata/school.river"), .{});
    played.setStdIn(.{ .bytes = "" });
    played.expectExitCode(0);
    played.expectStdOutEqual(school_played);
    test_step.dependOn(&played.step);
    const excerpts = riverrun.addExcerptsTest(b, river, .{ .package = package.builder, .stories = &documented.stories, .documents = &documented.documents }) orelse return null;
    test_step.dependOn(&b.addRunArtifact(excerpts).step);
}

// The school year through `addStory`, its compiler and tide's compiler side on one riverrun for the machine doing
// the building, then told by a test on the game's riverrun and tide, which must be one too or it does not compile.
fn storyTests(b: *std.Build, package: *std.Build.Dependency, filters: []const []const u8) ?*std.Build.Step.Compile {
    const side = compiler(b.dependency("tide", riverrun.building(b))) orelse return null;
    const school = riverrun.addStory(b, b.dependency("riverrun", riverrun.building(b)), .{
        .files = &.{package.path("src/front/testdata/school.river")},
        .vocabulary = package.path("tools/vocabulary.zig"),
        .packages = &.{.{ .name = "tide-compiler", .module = side }},
    });
    const runtime = package.module("tide");
    const river = b.dependency("riverrun", .{ .target = runtime.resolved_target.?, .optimize = runtime.optimize.? });
    return b.addTest(.{
        .name = "tide-story-tests",
        .filters = filters,
        .root_module = b.createModule(.{
            .root_source_file = package.path("tools/story_test.zig"),
            .target = runtime.resolved_target,
            .optimize = runtime.optimize,
            .imports = &.{
                .{ .name = "riverrun", .module = river.module("riverrun") },
                .{ .name = "tide", .module = runtime },
                .{ .name = "story", .module = school.module },
            },
        }),
    });
}

fn imports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) []const std.Build.Module.Import {
    const aegis = b.dependency("aegis", .{ .target = target, .optimize = optimize });
    const river = b.dependency("riverrun", .{ .target = target, .optimize = optimize });
    return b.allocator.dupe(std.Build.Module.Import, &.{
        .{ .name = "aegis", .module = aegis.module("aegis") },
        .{ .name = "riverrun", .module = river.module("riverrun") },
    }) catch @panic("OOM");
}
