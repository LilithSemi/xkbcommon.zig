const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const xkb_mod = b.addModule("xkbcommon", .{
        .root_source_file = b.path("src/xkbcommon.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Pure-Zig XML parser (ianprime0509/zig-xml) for the registry. Zero C deps.
    const xml_dep = b.dependency("xml", .{ .target = target, .optimize = optimize });
    xkb_mod.addImport("xml", xml_dep.module("xml"));

    // Pure-Zig XCB implementation for the x11 module. Zero C deps.
    const xcb_dep = b.dependency("xcb", .{ .target = target, .optimize = optimize });
    xkb_mod.addImport("xcb", xcb_dep.module("xcb"));

    // Generate the keysym tables at build time from xorgproto's keysymdef.h and
    // XF86keysym.h (parsed as text, no C compiled), so nothing generated is committed.
    const xorgproto = b.dependency("xorgproto", .{});

    const gen_root = b.createModule(.{
        .root_source_file = b.path("generator/keysyms.zig"),
        .target = target,
        .optimize = optimize,
    });
    const gen_exe = b.addExecutable(.{ .name = "keysym-gen", .root_module = gen_root });
    const gen_run = b.addRunArtifact(gen_exe);
    gen_run.addFileArg(xorgproto.path("include/X11/keysymdef.h"));
    gen_run.addFileArg(xorgproto.path("include/X11/XF86keysym.h"));
    const tables_out = gen_run.addOutputFileArg("keysym_tables.zig");
    const tables_mod = b.createModule(.{ .root_source_file = tables_out });
    xkb_mod.addImport("keysym_tables", tables_mod);

    const test_step = b.step("test", "Run tests");
    const xkb_tests = b.addTest(.{ .root_module = xkb_mod });
    test_step.dependOn(&b.addRunArtifact(xkb_tests).step);

    const gen_test_root = b.createModule(.{
        .root_source_file = b.path("generator/keysyms.zig"),
        .target = target,
        .optimize = optimize,
    });
    const gen_tests = b.addTest(.{ .root_module = gen_test_root });
    test_step.dependOn(&b.addRunArtifact(gen_tests).step);
}
