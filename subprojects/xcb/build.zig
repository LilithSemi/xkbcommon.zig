const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("xcb", .{
        .root_source_file = b.path("src/xcb.zig"),
        .target = target,
        .optimize = optimize,
    });

    const xcb_mod = b.createModule(.{
        .root_source_file = b.path("src/xcb.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run xcb tests");
    const xcb_tests = b.addTest(.{ .root_module = xcb_mod });
    test_step.dependOn(&b.addRunArtifact(xcb_tests).step);

    // Live-server validation probe (requires a running X server on :99)
    const probe_mod = b.createModule(.{
        .root_source_file = b.path("probe.zig"),
        .target = target,
        .optimize = optimize,
    });
    probe_mod.addImport("xcb", xcb_mod);
    const probe_exe = b.addExecutable(.{
        .name = "xcb-probe",
        .root_module = probe_mod,
    });

    const run_probe = b.addRunArtifact(probe_exe);
    if (b.args) |args| run_probe.addArgs(args);
    b.step("run-probe", "Run live X server probe (needs Xvfb on :99)").dependOn(&run_probe.step);
}
