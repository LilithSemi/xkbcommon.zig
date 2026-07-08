const std = @import("std");
const Keysym = @import("../keysym.zig").Keysym;
const Context = @import("../context.zig").Context;
const ast = @import("ast.zig");
const mods = @import("mods.zig");
const ModMask = @import("../keymap.zig").ModMask;

pub const Value = union(enum) {
    int: i64,
    boolean: bool,
    string: []const u8,
    keysym: Keysym,
    ident: []const u8,
    mods: ModMask,
};

pub fn eval(expr: *const ast.Expr, ctx: *Context) !Value {
    switch (expr.*) {
        .integer => |v| return .{ .int = v },
        .boolean => |v| return .{ .boolean = v },
        .string => |v| return .{ .string = v },
        .keyname => |v| return .{ .string = v },
        .ident => |name| {
            if (std.ascii.eqlIgnoreCase(name, "none")) return .{ .mods = 0 };
            if (mods.realModMask(name)) |mask| return .{ .mods = mask };
            return .{ .ident = name };
        },
        .unary => |u| {
            const rhs = try eval(u.rhs, ctx);
            switch (u.op) {
                .negate => {
                    const v = switch (rhs) {
                        .int => |x| x,
                        else => return error.NotConstant,
                    };
                    return .{ .int = -v };
                },
                .unary_plus => return rhs,
                else => return error.NotConstant,
            }
        },
        .binary => |b| {
            const lhs_val = try eval(b.lhs, ctx);
            const rhs_val = try eval(b.rhs, ctx);
            const lv = switch (lhs_val) {
                .int => |x| x,
                else => return error.NotConstant,
            };
            const rv = switch (rhs_val) {
                .int => |x| x,
                else => return error.NotConstant,
            };
            switch (b.op) {
                .add => return .{ .int = std.math.add(i64, lv, rv) catch return error.NotConstant },
                .sub => return .{ .int = std.math.sub(i64, lv, rv) catch return error.NotConstant },
                .mul => return .{ .int = std.math.mul(i64, lv, rv) catch return error.NotConstant },
                .div => {
                    if (rv == 0) return error.NotConstant;
                    return .{ .int = @divTrunc(lv, rv) };
                },
                else => return error.NotConstant,
            }
        },
        else => return error.NotConstant,
    }
}

test "expr_eval: integer arithmetic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const io = std.testing.io;
    const ctx = try @import("../context.zig").Context.create(
        std.testing.allocator,
        io,
        .{ .no_default_includes = true },
        null,
    );
    defer ctx.destroy();

    const one = try alloc.create(ast.Expr);
    one.* = .{ .integer = 1 };
    const two = try alloc.create(ast.Expr);
    two.* = .{ .integer = 2 };
    const add_expr = ast.Expr{ .binary = .{ .op = .add, .lhs = one, .rhs = two } };

    const r = try eval(&add_expr, ctx);
    try std.testing.expect(r == .int);
    try std.testing.expectEqual(@as(i64, 3), r.int);
}

test "expr_eval: ident Shift -> mods 0x1" {
    const io = std.testing.io;
    const ctx = try @import("../context.zig").Context.create(
        std.testing.allocator,
        io,
        .{ .no_default_includes = true },
        null,
    );
    defer ctx.destroy();

    const e = ast.Expr{ .ident = "Shift" };
    const r = try eval(&e, ctx);
    try std.testing.expect(r == .mods);
    try std.testing.expectEqual(@as(ModMask, 0x1), r.mods);
}

test "expr_eval: ident None -> mods 0" {
    const io = std.testing.io;
    const ctx = try @import("../context.zig").Context.create(
        std.testing.allocator,
        io,
        .{ .no_default_includes = true },
        null,
    );
    defer ctx.destroy();

    const e = ast.Expr{ .ident = "None" };
    const r = try eval(&e, ctx);
    try std.testing.expect(r == .mods);
    try std.testing.expectEqual(@as(ModMask, 0), r.mods);
}

test "expr_eval: string literal" {
    const io = std.testing.io;
    const ctx = try @import("../context.zig").Context.create(
        std.testing.allocator,
        io,
        .{ .no_default_includes = true },
        null,
    );
    defer ctx.destroy();

    const e = ast.Expr{ .string = "hi" };
    const r = try eval(&e, ctx);
    try std.testing.expect(r == .string);
    try std.testing.expectEqualStrings("hi", r.string);
}
