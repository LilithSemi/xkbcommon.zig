const std = @import("std");
const x11_build = @import("x11");

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

    // Pure-Zig X11 client for src/x11.zig. Zero C deps.
    const x11_dep = b.dependency("x11", .{ .target = target, .optimize = optimize });
    xkb_mod.addImport("x11", x11_dep.module("x11"));

    // XKB wire bindings are generated from the official xcbproto XML rather than
    // hand-written, so the struct layouts track the protocol definition instead
    // of a transcription of it. The XML ships inside x11.zig's own xcbproto
    // dependency, so reach it through that builder.
    //
    // generateProtocol wires `x11` into each generated module, but not `xproto`:
    // xkb.xml refers to xproto types (ATOM, KEYCODE, KEYSYM), so xkb.xml is
    // passed as an import seed AND the resulting module gets `xproto` added here.
    const xcbproto = x11_dep.builder.dependency("xcbproto", .{});
    const xproto_xml = xcbproto.path("src/xproto.xml");

    const xproto_mod = x11_build.generateProtocol(b, x11_dep, xproto_xml, &.{}, "xproto");
    const xkbproto_mod = x11_build.generateProtocol(b, x11_dep, xcbproto.path("src/xkb.xml"), &.{xproto_xml}, "xkb");
    xkbproto_mod.addImport("xproto", xproto_mod);

    xkb_mod.addImport("xproto", xproto_mod);
    xkb_mod.addImport("xkbproto", xkbproto_mod);

    // Generate the keysym tables at build time from xorgproto's keysymdef.h and
    // XF86keysym.h (parsed as text, no C compiled), so nothing generated is committed.
    const xorgproto = b.dependency("xorgproto", .{});

    // The keysym-gen generator runs at build time on the HOST, so it must be
    // host-native. Building it for `target` breaks cross-compilation (e.g.
    // `-Dcpu=apple_m1`): the generator becomes a target binary that cannot
    // execute on the host (Illegal instruction). The `tables_mod` it emits is
    // plain generated Zig with no target of its own, so it inherits the
    // importing module's target and stays correct.
    const gen_root = b.createModule(.{
        .root_source_file = b.path("generator/keysyms.zig"),
        .target = b.graph.host,
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
