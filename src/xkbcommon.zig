const std = @import("std");
pub const keysym = @import("keysym.zig");
pub const Keysym = keysym.Keysym;
pub const context = @import("context.zig");
pub const Context = context.Context;
pub const LogLevel = context.LogLevel;
pub const Atom = context.Atom;
pub const Flags = context.Flags;
pub const OpenedFile = context.OpenedFile;
pub const Keymap = @import("keymap.zig").Keymap;
pub const State = @import("state.zig").State;
pub const ComposeTable = @import("compose/table.zig").ComposeTable;
pub const ComposeState = @import("compose/state.zig").ComposeState;
pub const Registry = @import("registry.zig").Registry;
pub const x11 = @import("x11.zig");

test "root module builds" {
    try std.testing.expect(true);
}

test "generated tables import" {
    const tables = @import("keysym_tables");
    try std.testing.expectEqual(@as(u32, 0x41), tables.keys.A);
    try std.testing.expect(tables.names_by_name.len > 2000);
}

test {
    _ = @import("keysym.zig");
    _ = @import("keysym/unicode.zig");
    _ = @import("keysym/names.zig");
    _ = @import("keysym/case.zig");
    _ = @import("context.zig");
    _ = @import("xkbcomp/lexer.zig");
    _ = @import("xkbcomp/ast.zig");
    _ = @import("xkbcomp/parser.zig");
    _ = @import("xkbcomp/include.zig");
    _ = @import("keymap.zig");
    _ = @import("xkbcomp/mods.zig");
    _ = @import("xkbcomp/expr_eval.zig");
    _ = @import("xkbcomp/action.zig");
    _ = @import("xkbcomp/compile_types.zig");
    _ = @import("xkbcomp/compile_keycodes.zig");
    _ = @import("xkbcomp/compile_compat.zig");
    _ = @import("xkbcomp/compile_symbols.zig");
    _ = @import("xkbcomp/compile_link.zig");
    _ = @import("xkbcomp/compile_geometry.zig");
    _ = @import("xkbcomp/rules.zig");
    _ = @import("state.zig");
    _ = @import("xkbcomp/serialize.zig");
    _ = @import("compose/parser.zig");
    _ = @import("compose/table.zig");
    _ = @import("compose/state.zig");
    _ = @import("registry.zig");
    _ = @import("x11.zig");
}

test "name round-trips across a sample" {
    const samples = [_]u32{ 0x0041, 0xff0d, 0x00e9, 0x01a1, 0xff67, 0x0020 };
    var buf: [64]u8 = undefined;
    for (samples) |v| {
        const ks: Keysym = @enumFromInt(v);
        const name = try ks.getName(&buf);
        const back = keysym.fromName(name, .{}) orelse return error.Missing;
        try std.testing.expectEqual(v, @intFromEnum(back));
    }
}

test "unicode round-trips" {
    try std.testing.expectEqual(@as(u21, 'A'), (@as(Keysym, @enumFromInt(keysym.keys.A))).toUtf32());
    try std.testing.expectEqual(@as(u32, 0x01a1), @intFromEnum(Keysym.fromUtf32(0x0104)));
}

test "named constants resolve" {
    try std.testing.expectEqual(@as(u32, 0xff0d), keysym.keys.Return);
}

test "integration: create context, append include path, query via public API" {
    const io = std.testing.io;
    const ctx = try Context.create(std.testing.allocator, io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();
    try ctx.includePathAppend("/usr/share/xkb");
    try std.testing.expectEqual(@as(usize, 1), ctx.numIncludePaths());
    try std.testing.expectEqualStrings("/usr/share/xkb", ctx.includePath(0).?);
    try std.testing.expect(ctx.includePath(1) == null);
}

test "integration: atom intern dedup and atomText round-trip via public Context" {
    const io = std.testing.io;
    const ctx = try Context.create(std.testing.allocator, io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();
    const a1: Atom = try ctx.intern("hello");
    const a2: Atom = try ctx.intern("hello");
    const a3: Atom = try ctx.intern("world");
    try std.testing.expectEqual(a1, a2);
    try std.testing.expect(a1 != a3);
    try std.testing.expectEqualStrings("hello", ctx.atomText(a1));
    try std.testing.expectEqualStrings("world", ctx.atomText(a3));
}

test "integration: parseLogLevel resolves via public surface" {
    try std.testing.expectEqual(LogLevel.warning, context.parseLogLevel("warning").?);
    try std.testing.expectEqual(LogLevel.err, context.parseLogLevel("ERROR").?);
    try std.testing.expect(context.parseLogLevel("bogus") == null);
}

test "integration: open finds file in tmpDir include path" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "layout.xkb", .data = "test layout data" });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const real = buf[0..n];
    const ctx = try Context.create(std.testing.allocator, io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();
    try ctx.includePathAppend(real);
    var found: OpenedFile = ctx.open("layout.xkb") orelse return error.NotFound;
    found.close();
    try std.testing.expect(ctx.open("missing.xkb") == null);
}
